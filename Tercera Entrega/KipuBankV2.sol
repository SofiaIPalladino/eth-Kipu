// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/AccessControl.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/smartcontractkit/chainlink/v1.11.0/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBankV2
 * @author Sofía Isabella Palladino
 * @notice Banco descentralizado multi-token con límites globales y diarios por usuario, usando oráculos de precios.
 * @dev Mejoras respecto a la versión original:
 *      - Soporte para múltiples tokens ERC20 además de ETH.
 *      - Conversión de depósitos y retiros a USD usando Chainlink.
 *      - Límite diario de retiro por usuario y límite global en USD.
 *      - Roles granulares (ADMIN, OPERATOR, RISK) para gestión segura de tokens y feeds.
 *      - Transferencias internas entre usuarios.
 *      - Protección contra precios stale y control de decimales.
 *      - Eventos detallados y errores personalizados para mayor trazabilidad.
 *      - Patrones de seguridad CEI y reentrancy guard en depósitos y retiros.
 *      - Receive/fallback protegidos para evitar depósitos accidentales.
 */


contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================================
    //                     TIPOS Y CONSTANTES
    // =============================================================

    /// @notice Role for administrators who manage tokens and high-level settings.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice Role for operators allowed to pause/unpause and perform day-to-day ops.
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role for risk managers allowed to update/validate price feeds and staleness.
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");

    /// @notice Alias for native ETH in mappings (use this constant when referring to ETH).
    address public constant ETH_ADDRESS = address(0);

    /// @notice Max token decimals allowed when registering a token (prevents huge exponents).
    uint8 public constant MAX_ALLOWED_TOKEN_DECIMALS = 36;

    // =============================================================
    //                      VARIABLES DE ESTADO
    // =============================================================

    /// @notice Total cap of the vault expressed in USD with 18 decimals (usd18).
    uint256 public immutable bankCapUsd18;

    /// @notice Running approximate total of deposited value in USD (usd18).
    /// @dev This is updated on deposit/withdraw and is not recalculated on price moves.
    uint256 public totalDepositedUsd18;

    /// @notice Daily withdraw limit per user expressed in USD (usd18). Zero means no limit.
    uint256 public perUserDailyWithdrawLimitUsd18;

    // ---------------------------
    // Token / balances storage
    // ---------------------------

    /// @notice Mapping token => user => raw balance (wei for ETH or token base units)
    mapping(address => mapping(address => uint256)) public balances;

    /// @notice Chainlink feed registered per token (token => Aggregator)
    mapping(address => AggregatorV3Interface) public priceFeeds;

    /// @notice Flag to indicate token support (token => supported)
    mapping(address => bool) public supportedTokens;

    /// @notice Token decimals cache (token => decimals). For ETH use 18.
    mapping(address => uint8) public tokenDecimals;

    // ---------------------------
    // Withdraw window tracking
    // ---------------------------

    /// @notice Withdraw window tracks user daily spend in usd18
    struct WithdrawWindow {
        /// @notice windowStart is the unix timestamp (seconds) of the current day's start (UTC).
        uint64 windowStart;
        /// @notice spentUsd18 is the accumulated usd18 spent within the current window.
        uint192 spentUsd18;
    }
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    /// @notice Maximum allowed age (seconds) of a price feed answer before considered stale.
    uint256 public maxPriceAgeSeconds = 24 hours;
 

    // =============================================================
    //                           EVENTOS
    // =============================================================
   
    /// @notice Se emite cuando un usuario deposita ETH o un token ERC20
    /// @param user Dirección del usuario que realiza el depósito
    /// @param token Dirección del token depositado (0 para ETH)
    /// @param amountRaw Cantidad depositada en unidades del token (wei o base units)
    /// @param valueUsd18 Valor equivalente en USD18 al momento del depósito
    event Deposit(address indexed user, address indexed token, uint256 amountRaw, uint256 valueUsd18);

    /// @notice Se emite cuando un usuario retira ETH o un token ERC20
    /// @param user Dirección del usuario que realiza el retiro
    /// @param token Dirección del token retirado (0 para ETH)
    /// @param amountRaw Cantidad retirada en unidades del token (wei o base units)
    /// @param valueUsd18 Valor equivalente en USD18 al momento del retiro
    event Withdrawal(address indexed user, address indexed token, uint256 amountRaw, uint256 valueUsd18);

    /// @notice Se emite cuando se agrega un nuevo token al banco
    /// @param token Dirección del token agregado
    /// @param priceFeed Dirección del feed de precios Chainlink asociado
    /// @param decimals Cantidad de decimales del token
    event TokenAdded(address indexed token, address indexed priceFeed, uint8 decimals);

    /// @notice Se emite cuando se actualiza el feed de precios de un token
    /// @param token Dirección del token cuya fuente de precio se actualiza
    /// @param oldFeed Dirección del feed anterior
    /// @param newFeed Dirección del nuevo feed de precios
    event PriceFeedUpdated(address indexed token, address indexed oldFeed, address indexed newFeed);

    /// @notice Se emite cuando se actualiza el límite diario de retiro por usuario
    /// @param newLimitUsd18 Nuevo límite diario en USD18
    event PerUserDailyWithdrawLimitUpdated(uint256 newLimitUsd18);

    /// @notice Se emite cuando el contrato es pausado o despausado
    /// @param isPaused True si el contrato está pausado, false si se reanuda
    event PauseStatusChanged(bool isPaused);

    /// @notice Se emite cuando un administrador ajusta manualmente el total depositado
    /// @param deltaUsd18 Cambio aplicado al total depositado (positivo o negativo)
    /// @param reason Motivo del ajuste
    event AdminAdjustedTotal(int256 deltaUsd18, string reason);

    /// @notice Se emite cuando se actualiza el tiempo máximo permitido para la edad de los precios
    /// @param oldSeconds Tiempo anterior en segundos
    /// @param newSeconds Nuevo tiempo máximo en segundos
    event MaxPriceAgeUpdated(uint256 oldSeconds, uint256 newSeconds);

     
    // =============================================================
    //                          ERRORES
    // =============================================================

    /// @notice Revert cuando se pasa un monto inválido (ej. 0) a depositar o retirar
    error InvalidAmount();

    /// @notice Revert cuando se pasa la dirección cero o inválida como parámetro
    error InvalidAddress();

    /// @notice Revert cuando se intenta usar un token que no está soportado por el banco
    error TokenNotSupported();

    /// @notice Revert cuando el usuario no tiene balance suficiente para retirar
    error InsufficientBalance();

    /// @notice Revert cuando el depósito excede la capacidad máxima del banco
    error BankCapExceeded();

    /// @notice Revert cuando la transferencia de ETH o token falla
    error TransferFailed();

    /// @notice Revert cuando el feed de precios no devuelve un valor válido
    error InvalidPriceFeed();

    /// @notice Revert cuando el precio del feed está desactualizado o la ronda no es válida
    error StalePrice();

    /// @notice Revert cuando el retiro supera el límite diario por usuario
    error WithdrawLimitExceeded();

    /// @notice Revert cuando los decimales del token exceden el máximo permitido (para cálculos seguros)
    error DecimalsTooLarge();


    // =============================================================
    //                       MODIFICADORES
    // =============================================================

    /// @notice Verifica que el monto pasado como argumento sea mayor a cero
    /// @dev Lanza `InvalidAmount` si `amount` es 0
    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    /// @notice Verifica que el token esté registrado y soportado por el banco
    /// @dev Lanza `TokenNotSupported` si el token no está en `supportedTokens`
    modifier onlySupportedToken(address token) {
        if (!supportedTokens[token]) revert TokenNotSupported();
        _;
    }

    // =============================================================
    //                       CONSTRUCTOR
    // =============================================================

    /// @notice Inicializa el banco con los parámetros principales
    /// @param _bankCapUsd18 Límite máximo total del banco en USD con 18 decimales
    /// @param _ethPriceFeed Dirección del oráculo de Chainlink para ETH/USD
    /// @param _perUserDailyWithdrawLimitUsd18 Límite diario de retiro por usuario en USD18
    /// @dev Asigna los roles al desplegador y registra ETH como token soportado
    
    constructor(
        uint256 _bankCapUsd18,
        address _ethPriceFeed,
        uint256 _perUserDailyWithdrawLimitUsd18
    ) {
        if (_bankCapUsd18 == 0) revert InvalidAmount();
        if (_ethPriceFeed == address(0)) revert InvalidAddress();

        bankCapUsd18 = _bankCapUsd18;
        perUserDailyWithdrawLimitUsd18 = _perUserDailyWithdrawLimitUsd18;

        // grant roles to deployer
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(RISK_ROLE, msg.sender);

        // register ETH feed (decimals typically 8)
        _addTokenInternal(ETH_ADDRESS, _ethPriceFeed, 18);
    }

    // =============================================================
    // ---------------- Admin / Operator functions ----------------
    // =============================================================

    /// @notice Registra un nuevo token soportado por el banco
    /// @param token Dirección del token ERC20 a registrar
    /// @param feed Dirección del oráculo de Chainlink correspondiente
    /// @param decimals Decimales del token (para cálculo interno)
    /// @dev Solo accesible por cuentas con rol ADMIN_ROLE
    function registerToken(address token, address feed, uint8 decimals) external onlyRole(ADMIN_ROLE) {
        _addTokenInternal(token, feed, decimals);
    }

    /// @notice Actualiza la dirección del feed de precios de un token existente
    /// @param token Dirección del token a actualizar
    /// @param newFeed Nueva dirección del oráculo Chainlink
    /// @dev Solo accesible por cuentas con rol RISK_ROLE
    function updatePriceFeed(address token, address newFeed) external onlyRole(RISK_ROLE) {
        AggregatorV3Interface old = priceFeeds[token];
        priceFeeds[token] = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(token, address(old), address(newFeed));
    }

    /// @notice Actualiza el límite diario de retiro por usuario en USD18
    /// @param newLimitUsd18 Nuevo límite diario por usuario en USD18
    /// @dev Solo accesible por cuentas con rol ADMIN_ROLE
    function setPerUserDailyWithdrawLimitUsd18(uint256 newLimitUsd18) external onlyRole(ADMIN_ROLE) {
        perUserDailyWithdrawLimitUsd18 = newLimitUsd18;
        emit PerUserDailyWithdrawLimitUpdated(newLimitUsd18);
    }

    /// @notice Establece la edad máxima permitida para los precios del feed
    /// @param newMaxSeconds Nuevo valor máximo en segundos
    /// @dev Solo accesible por cuentas con rol RISK_ROLE
    function setMaxPriceAgeSeconds(uint256 newMaxSeconds) external onlyRole(RISK_ROLE) {
        uint256 old = maxPriceAgeSeconds;
        maxPriceAgeSeconds = newMaxSeconds;
        emit MaxPriceAgeUpdated(old, newMaxSeconds);
    }

    /// @notice Emergency admin adjustment of totalDepositedUsd18 (signed int).
    /// @dev Only ADMIN_ROLE. Use only in emergencies (e.g., reconcile accounting).
    /// @param deltaUsd18 signed delta: positive increases total, negative decreases.
    /// @param reason human readable reason for audit logs.
    function adminAdjustTotalUsd18(int256 deltaUsd18, string calldata reason) external onlyRole(ADMIN_ROLE) {
        if (deltaUsd18 < 0) {
            uint256 abs = uint256(-deltaUsd18);
            if (abs >= totalDepositedUsd18) totalDepositedUsd18 = 0;
            else totalDepositedUsd18 -= abs;
        } else {
            totalDepositedUsd18 += uint256(deltaUsd18);
            if (totalDepositedUsd18 > bankCapUsd18) revert BankCapExceeded();
        }
        emit AdminAdjustedTotal(deltaUsd18, reason);
    }

    /// @notice Pause operations (only OPERATOR_ROLE).
    function pause() external onlyRole(OPERATOR_ROLE) {
        _pause();
        emit PauseStatusChanged(true);
    }

    /// @notice Unpause operations (only OPERATOR_ROLE).
    function unpause() external onlyRole(OPERATOR_ROLE) {
        _unpause();
        emit PauseStatusChanged(false);
    }


    // =============================================================
    // ---------------- Deposits ----------------
    // =============================================================

    /// @notice Deposita ETH en el banco y actualiza el balance del usuario
    /// @dev Convierte el valor depositado a USD18 usando el oráculo de ETH y verifica el límite total del banco
    /// @dev La función falla si el contrato está pausado, si el monto es 0 o si se excede el límite total
    /// @dev Se utiliza reentrancy guard para evitar ataques de reentrada
    function depositETH() external payable whenNotPaused nonReentrant onlyValidAmount(msg.value) {
        uint256 usd18 = _convertToUsd18(ETH_ADDRESS, msg.value);
        _enforceBankCapOnCheck(usd18);

        // Efectos sobre el estado
        balances[msg.sender][ETH_ADDRESS] += msg.value;
        totalDepositedUsd18 += usd18;

        emit Deposit(msg.sender, ETH_ADDRESS, msg.value, usd18);
    }

    /// @notice Deposita un token ERC20 soportado en el banco
    /// @param token Dirección del token a depositar
    /// @param amountRaw Cantidad de token a depositar en unidades mínimas (wei, satoshis, etc.)
    /// @dev Convierte el valor del token a USD18 usando el feed correspondiente y verifica el límite total del banco
    /// @dev La función falla si el contrato está pausado, si el token no está soportado, si es ETH, si el monto es 0 o si se excede el límite total
    /// @dev Se utiliza reentrancy guard y SafeERC20 para transferencias seguras
    function depositToken(address token, uint256 amountRaw)
        external
        whenNotPaused
        nonReentrant
        onlyValidAmount(amountRaw)
        onlySupportedToken(token)
    {
        if (token == ETH_ADDRESS) revert InvalidAddress();

        uint256 usd18 = _convertToUsd18(token, amountRaw);
        _enforceBankCapOnCheck(usd18);

        // Efectos sobre el estado
        balances[msg.sender][token] += amountRaw;
        totalDepositedUsd18 += usd18;

        // Transferencia segura del token desde el usuario al contrato
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountRaw);

        emit Deposit(msg.sender, token, amountRaw, usd18);
    }

    // =============================================================
    // ---------------- Withdrawals ----------------
    // =============================================================

    /// @notice Retira ETH del banco
    /// @param amountWei Cantidad de ETH a retirar en wei
    /// @dev Convierte el valor retirado a USD18 usando el oráculo de ETH
    /// @dev Verifica que el usuario tenga saldo suficiente y que no se exceda el límite diario
    /// @dev La función falla si el contrato está pausado, si el monto es 0 o si hay saldo insuficiente
    /// @dev Se utiliza reentrancy guard para evitar ataques de reentrada
    function withdrawETH(uint256 amountWei)
        external
        whenNotPaused
        nonReentrant
        onlyValidAmount(amountWei)
    {
        if (balances[msg.sender][ETH_ADDRESS] < amountWei) revert InsufficientBalance();

        uint256 usd18 = _convertToUsd18(ETH_ADDRESS, amountWei);
        _enforceAndConsumeWithdrawLimit(msg.sender, usd18);

        // Efectos sobre el estado
        balances[msg.sender][ETH_ADDRESS] -= amountWei;
        totalDepositedUsd18 = totalDepositedUsd18 > usd18 ? totalDepositedUsd18 - usd18 : 0;

        // Interacción segura con el usuario
        (bool ok, ) = msg.sender.call{value: amountWei}("");
        if (!ok) revert TransferFailed();

        emit Withdrawal(msg.sender, ETH_ADDRESS, amountWei, usd18);
    }

    /// @notice Retira un token ERC20 soportado del banco
    /// @param token Dirección del token a retirar
    /// @param amountRaw Cantidad de token a retirar en unidades mínimas (wei, satoshis, etc.)
    /// @dev Convierte el valor del token a USD18 usando el feed correspondiente
    /// @dev Verifica que el usuario tenga saldo suficiente y que no se exceda el límite diario
    /// @dev La función falla si el contrato está pausado, si el token no está soportado, si es ETH, si el monto es 0 o si hay saldo insuficiente
    /// @dev Se utiliza reentrancy guard y SafeERC20 para transferencias seguras
    function withdrawToken(address token, uint256 amountRaw)
        external
        whenNotPaused
        nonReentrant
        onlyValidAmount(amountRaw)
        onlySupportedToken(token)
    {
        if (token == ETH_ADDRESS) revert InvalidAddress();
        if (balances[msg.sender][token] < amountRaw) revert InsufficientBalance();

        uint256 usd18 = _convertToUsd18(token, amountRaw);
        _enforceAndConsumeWithdrawLimit(msg.sender, usd18);

        // Efectos sobre el estado
        balances[msg.sender][token] -= amountRaw;
        totalDepositedUsd18 = totalDepositedUsd18 > usd18 ? totalDepositedUsd18 - usd18 : 0;

        // Transferencia segura del token al usuario
        IERC20(token).safeTransfer(msg.sender, amountRaw);

        emit Withdrawal(msg.sender, token, amountRaw, usd18);
    }


    // =============================================================
    // ---------------- Internal transfers ----------------
    // =============================================================

    /// @notice Transfiere tokens internamente entre cuentas dentro del banco
    /// @param token Dirección del token a transferir
    /// @param to Dirección del usuario receptor
    /// @param amountRaw Cantidad de token a transferir en unidades mínimas
    /// @dev Solo permite transferencias de tokens soportados, no permite ETH
    /// @dev Verifica que el remitente tenga saldo suficiente y que la cantidad sea válida
    /// @dev La función falla si el contrato está pausado, si la dirección destino es 0 o si no hay saldo suficiente
    /// @dev Esta función no realiza transferencias externas; solo ajusta balances internos
    /// @dev Se utiliza `nonReentrant` para seguridad, aunque no interactúa con contratos externos
    function transferInternal(address token, address to, uint256 amountRaw)
        external
        whenNotPaused
        nonReentrant
        onlyValidAmount(amountRaw)
        onlySupportedToken(token)
    {
        if (to == address(0)) revert InvalidAddress();
        if (balances[msg.sender][token] < amountRaw) revert InsufficientBalance();

        // Ajuste de balances internos
        balances[msg.sender][token] -= amountRaw;
        balances[to][token] += amountRaw;

        // Emite evento de depósito para mantener telemetría (opcional: cambiar a InternalTransfer)
        emit Deposit(msg.sender, token, 0, 0);
    }


    // =============================================================
    // ---------------- Views / Helpers ----------------
    // =============================================================

    /// @notice Obtiene el precio más reciente de un token desde su oráculo Chainlink, validando frescura y consistencia
    /// @param token Dirección del token a consultar
    /// @return price Precio actual del token (sin escalar a USD18, según feed)
    /// @return priceDecimals Cantidad de decimales del precio retornado por el oráculo
    /// @dev Requiere que el token tenga un oráculo registrado
    /// @dev Requiere que la respuesta del oráculo sea positiva y no esté desactualizada
    /// @dev Revertirá si el feed es inválido o si la información del precio está desactualizada según `maxPriceAgeSeconds`
    function _getLatestPriceValidated(address token) internal view returns (uint256 price, uint8 priceDecimals) {
        AggregatorV3Interface feed = priceFeeds[token];
        if (address(feed) == address(0)) revert InvalidPriceFeed();
        (uint80 roundId, int256 answer, , uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();

        if (answer <= 0) revert InvalidPriceFeed();
        if (answeredInRound < roundId) revert StalePrice();
        if (updatedAt == 0) revert StalePrice();
        if (block.timestamp - updatedAt > maxPriceAgeSeconds) revert StalePrice();

        price = uint256(answer);
        priceDecimals = feed.decimals();
    }

    /**
    * @dev Convierte una cantidad de token "raw" a USD con 18 decimales de precisión (USD18)
    * @param token Dirección del token a convertir
    * @param amountRaw Cantidad de token sin normalizar
    * @return usd18 Valor equivalente en USD18
    * @dev La fórmula usada: usd18 = amountRaw * price * 1e18 / (10^(tokenDecimals + priceDecimals))
    * @dev Revertirá si los decimales del token exceden `MAX_ALLOWED_TOKEN_DECIMALS`
    */
    function _convertToUsd18(address token, uint256 amountRaw) internal view returns (uint256 usd18) {
        if (amountRaw == 0) return 0;
        (uint256 price, uint8 priceDecimals) = _getLatestPriceValidated(token);
        uint8 td = tokenDecimals[token];
        if (td > MAX_ALLOWED_TOKEN_DECIMALS) revert DecimalsTooLarge();

        uint256 numerator = amountRaw * price;
        uint256 denom = 10 ** (uint256(td) + uint256(priceDecimals));
        usd18 = (numerator * 1e18) / denom;
    }

    /**
    * @notice Calcula la cantidad de wei (ETH) necesaria para alcanzar un objetivo en USD18
    * @param usd18 Objetivo en USD con 18 decimales
    * @return weiReq Cantidad de wei requerida
    * @dev Usa división redondeando hacia arriba (ceil)
    * @dev Fórmula: wei = ceil(usd18 * 10^priceDecimals / price)
    */
    function quoteWeiForUsd18(uint256 usd18) external view returns (uint256 weiReq) {
        (uint256 price, uint8 priceDecimals) = _getLatestPriceValidated(ETH_ADDRESS);
        uint256 mult = 10 ** uint256(priceDecimals);
        weiReq = (usd18 * mult + price - 1) / price; // ceil division
    }

    /**
    * @notice Obtiene el valor de un token en USD18
    * @param token Dirección del token
    * @param amountRaw Cantidad de token sin normalizar
    * @return Equivalente en USD18
    */
    function getValueUsd18(address token, uint256 amountRaw) external view returns (uint256) {
        return _convertToUsd18(token, amountRaw);
    }

    /**
    * @notice Retorna la capacidad disponible del banco en USD18
    * @return Capacidad restante en USD18
    * @dev Si el total depositado supera el límite, retorna 0
    */
    function getAvailableCapacityUsd18() external view returns (uint256) {
        if (totalDepositedUsd18 >= bankCapUsd18) return 0;
        return bankCapUsd18 - totalDepositedUsd18;
    }

    /**
    * @notice Retorna cuánto puede retirar un usuario hoy en USD18
    * @param user Dirección del usuario
    * @return Monto restante que puede retirar en USD18
    * @dev Si el límite diario está desactivado (0), retorna uint256.max
    */
    function getRemainingWithdrawLimitUsd18(address user) external view returns (uint256) {
        uint256 limit = perUserDailyWithdrawLimitUsd18;
        if (limit == 0) return type(uint256).max;
        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow memory w = _userWithdrawWindow[user];
        uint256 spent = (w.windowStart == currentStart) ? uint256(w.spentUsd18) : 0;
        if (spent >= limit) return 0;
        return limit - spent;
    }

    // =============================================================
    // ---------------- Internal utilities ----------------
    // =============================================================

    /**
    * @notice Registra un token en el banco junto a su oráculo y decimales
    * @param token Dirección del token a registrar
    * @param priceFeed Dirección del oráculo Chainlink del token
    * @param decimals Decimales del token
    * @dev Revertirá si los decimales exceden `MAX_ALLOWED_TOKEN_DECIMALS`
    * @dev No hace nada si el token ya estaba registrado
    * @dev Emite el evento TokenAdded
    */
    function _addTokenInternal(address token, address priceFeed, uint8 decimals) internal {
        if (priceFeed == address(0)) revert InvalidAddress();
        if (supportedTokens[token]) return;
        if (decimals > MAX_ALLOWED_TOKEN_DECIMALS) revert DecimalsTooLarge();

        priceFeeds[token] = AggregatorV3Interface(priceFeed);
        supportedTokens[token] = true;
        tokenDecimals[token] = decimals;

        emit TokenAdded(token, priceFeed, decimals);
    }

    /**
    * @notice Verifica que la adición de un monto en USD18 no exceda el límite del banco
    * @param usd18Delta Monto en USD18 a agregar al total
    * @dev Revertirá si totalDepositedUsd18 + usd18Delta > bankCapUsd18
    */
    function _enforceBankCapOnCheck(uint256 usd18Delta) internal view {
        if (totalDepositedUsd18 + usd18Delta > bankCapUsd18) revert BankCapExceeded();
    }

    /**
    * @notice Verifica y consume el límite diario de retiro de un usuario
    * @param user Dirección del usuario
    * @param usd18 Monto en USD18 que se quiere retirar
    * @dev Reinicia la ventana diaria si cambió el día
    * @dev Revertirá si el nuevo total diario excede `perUserDailyWithdrawLimitUsd18`
    */
    function _enforceAndConsumeWithdrawLimit(address user, uint256 usd18) internal {
        uint256 limit = perUserDailyWithdrawLimitUsd18;
        if (limit == 0) return; // límite desactivado

        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow storage w = _userWithdrawWindow[user];

        if (w.windowStart != currentStart) {
            w.windowStart = currentStart;
            w.spentUsd18 = 0;
        }

        uint256 newSpent = uint256(w.spentUsd18) + usd18;
        if (newSpent > limit) revert WithdrawLimitExceeded();
        w.spentUsd18 = uint192(newSpent);
    }

    /**
    * @notice Retorna el inicio del día actual en UTC y el tamaño de la ventana (24h)
    * @return start Timestamp del inicio del día actual en segundos
    * @return window Duración de la ventana en segundos (siempre 86400)
    */
    function _currentDay() internal view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    // =============================================================
    // ---------------- Receive / Fallback ----------------
    // =============================================================

    /**
    * @notice Permite recibir ETH directamente, pero revertirá
    * @dev Se recomienda usar la función depositETH() para depósitos de ETH
    */
    receive() external payable {
        revert("Use depositETH()");
    }

    /**
    * @notice Función fallback para llamadas a funciones inexistentes
    * @dev Revertirá cualquier llamada a funciones no definidas en el contrato
    */
    fallback() external payable {
        revert("Function does not exist");
    }
}
