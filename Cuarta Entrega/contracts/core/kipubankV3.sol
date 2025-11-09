// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/AccessControl.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/smartcontractkit/chainlink/v1.11.0/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "https://raw.githubusercontent.com/Uniswap/v2-periphery/master/contracts/interfaces/IUniswapV2Router02.sol";
import "https://raw.githubusercontent.com/Uniswap/v2-core/v1.0.1/contracts/interfaces/IUniswapV2Factory.sol";

/**
 * @title KipuBankV3
 * @author Sofia Palladino
 *
 * @notice
 * Contrato bancario/puente que permite depositar activos ERC20 (o ETH) y convertirlos
 * a USDC mediante Uniswap V2 (o router compatible), mantener balances internos en USDC
 * (raw USDC unidades) y contabilizar el valor agregado en unidades USD con 18 decimales (usd18).
 *
 * @dev
 * - Usa AccessControl para roles administrativos y de operación.
 * - Soporta depósitos directos de USDC (sin swap) y swaps desde tokens/ETH hacia USDC.
 * - Mantiene límites globales (bankCapUsd18) y por-usuario diarios de retiro (perUserDailyWithdrawLimitUsd18).
 * - Lleva contabilidad adicional (BankAccounting) y registra depósitos por token y por usuario.
 * - Incluye medidas para tokens con fees on transfer (mide balance antes/después).
 * - Incluye manejo de slippage via slippageBps y verificación de mínimos antes de swap.
 * - Usa interfaces opcionales de Chainlink para feeds de precio (priceFeeds) aunque la contabilidad principal
 *   se basa en cantidades USDC convertidas y una conversión sencilla a "usd18" mediante decimales del token.
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ============================
    // Roles
    // ============================
    /// @notice Rol administrativo principal con poderes para configurar parámetros críticos.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    /// @notice Rol para operaciones diarias (puede ser usado para operaciones menos privilegiadas).
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    /// @notice Rol responsable de riesgos (p. ej. actualizar feeds, maxPriceAge, etc).
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");
    /// @notice Rol para managers con permisos intermedios.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // ============================
    // Constants
    // ============================
    /// @notice Dirección sentinela que representa ETH (no es un token ERC20).
    address public constant ETH_ADDRESS = address(0);
    /// @notice Límite de decimales permitido para tokens registrados (protección).
    uint8 public constant MAX_ALLOWED_TOKEN_DECIMALS = 36;
    /// @notice Denominador para base-points (BPS) que se usa para slippage y porcentajes.
    uint16 public constant BPS_DENOMINATOR = 10000;

    // ============================
    // Estado público
    // ============================
    /**
     * @notice Límite máximo global del "banco" expresado en unidades USD con 18 decimales (usd18).
     * @dev El admin puede actualizarlo; todas las comprobaciones de depósito usan esta unidad.
     */
    uint256 public bankCapUsd18;

    /**
     * @notice Suma acumulada de depósitos netos (en usd18) que todavía están contabilizados en el sistema.
     * @dev Se ajusta en depósitos, retiros y por adminAdjustTotalUsd18.
     */
    uint256 public totalDepositedUsd18;

    /**
     * @notice Límite diario por usuario para retiros, expresado en usd18.
     * @dev 0 = sin límite.
     */
    uint256 public perUserDailyWithdrawLimitUsd18;

    /// @notice Router Uniswap V2 (o compatible con interfaz IUniswapV2Router02).
    IUniswapV2Router02 public uniswapRouter;
    /// @notice Factory Uniswap V2 para determinar pares.
    IUniswapV2Factory public uniswapFactory;
    /// @notice Dirección de WETH conocida por el router (puede ser address(0) si no disponible).
    address public WETH;
    /// @notice Dirección inmutable del token USDC usado como referencia/moneda interna.
    address public immutable USDC;

    /// @notice Slippage permitido en bps (por ejemplo 500 = 5%).
    uint256 public slippageBps = 500;
    /// @notice Máxima edad permitida para precios (si se usan feeds); actualmente almacenada para referencia.
    uint256 public maxPriceAgeSeconds = 24 hours;

    /// @notice Lista de "intermediarios" opcionales para construir rutas de swap (tokens puente).
    address[] public intermediaries;

    // ============================
    // Estructuras
    // ============================
    /**
     * @notice Información registrada por token.
     * @param enabled Indica si el token está habilitado en el registro.
     * @param decimals Número de decimales del token (se usa para convertir a usd18).
     * @param totalDeposited Cantidad total depositada de este token (en unidades crudas del token).
     * @param totalConvertedUsd18 Total convertido a usd18 a partir de los depósitos de este token.
     */
    struct TokenInfo {
        bool enabled;
        uint8 decimals;
        uint256 totalDeposited;
        uint256 totalConvertedUsd18;
    }

    /**
     * @notice Información de depósitos por usuario por token.
     * @param amountToken Cantidad del token recibida (unidades crudas del token).
     * @param amountUSDC Cantidad en USDC crudo recibida al convertir (si aplica).
     * @param lastDeposit Timestamp del último depósito para este par usuario-token.
     */
    struct DepositInfo {
        uint256 amountToken;
        uint256 amountUSDC;
        uint256 lastDeposit;
    }

    /**
     * @notice Resumen contable global para auditoría rápida.
     * @param totalDepositsUsd18 Total de depósitos convertidos a usd18 (acumulado).
     * @param totalWithdrawalsUsd18 Total de retiros convertidos a usd18 (acumulado).
     * @param totalSwapsExecuted Contador de swaps ejecutados (no cuenta depósitos directos de USDC).
     * @param totalConvertedUSDC Total de unidades crudas de USDC convertidas y almacenadas por el sistema.
     * @param lastUpdateTimestamp Última vez que se actualizó esta estructura.
     */
    struct BankAccounting {
        uint256 totalDepositsUsd18;
        uint256 totalWithdrawalsUsd18;
        uint256 totalSwapsExecuted;
        uint256 totalConvertedUSDC;
        uint256 lastUpdateTimestamp;
    }

    /// @notice Estado de contabilidad global.
    BankAccounting public accounting;

    // ============================
    // Mappings / almacenamiento
    // ============================
    /// @notice Registro por token de TokenInfo.
    mapping(address => TokenInfo) public tokenRegistry;
    /// @notice Depósitos por usuario por token.
    mapping(address => mapping(address => DepositInfo)) public userDeposits;
    /// @notice Balance interno por usuario en unidades "raw" de USDC (no usd18).
    mapping(address => uint256) public userUSDCBalance;

    /// @notice (Opcional) price feed por token (Chainlink Aggregator). Puede ser address(0).
    mapping(address => AggregatorV3Interface) public priceFeeds;

    /**
     * @notice Ventana de retiro por usuario para limitar retiros diarios.
     * @dev windowStart = inicio de la ventana diaria (timestamp al inicio del día),
     *      spentUsd18 = cantidad gastada (en usd18) dentro de la ventana actual.
     */
    struct WithdrawWindow { uint64 windowStart; uint192 spentUsd18; }
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // ============================
    // Eventos
    // ============================
    /**
     * @notice Emitted cuando un usuario realiza un depósito (incluye swaps a USDC si aplica).
     * @param user Dirección del depositante.
     * @param token Token depositado (address(0) si fue ETH).
     * @param amountToken Cantidad de token recibida (o cantidad USDC si depositó USDC directamente).
     * @param amountUSDC Cantidad de USDC cruda obtenida por la conversión (o igual a amountToken si token == USDC).
     * @param timestamp Timestamp del depósito.
     */
    event DepositMade(address indexed user, address indexed token, uint256 amountToken, uint256 amountUSDC, uint256 timestamp);

    /**
     * @notice Emitted cuando un usuario realiza un retiro (envío de USDC fuera del sistema).
     * @param user Dirección que retiró.
     * @param token Token enviado (siempre USDC en la implementación actual).
     * @param amountUSDC Cantidad de USDC cruda enviada.
     * @param timestamp Timestamp del retiro.
     */
    event WithdrawalMade(address indexed user, address indexed token, uint256 amountUSDC, uint256 timestamp);

    /**
     * @notice Emitted cuando se ejecuta un swap desde un token hacia otro (normalmente hacia USDC).
     * @param fromToken Token origen (address(0) para ETH).
     * @param toToken Token destino.
     * @param amountIn Cantidad de token de entrada (unidades crudas).
     * @param amountOut Cantidad obtenida del token destino (unidades crudas).
     */
    event SwapExecuted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);

    /**
     * @notice Emitted cuando se cambia el estado (habilitado/deshabilitado) de un token en el registro.
     * @param token Token afectado.
     * @param enabled Nuevo estado.
     */
    event TokenStatusChanged(address indexed token, bool enabled);

    /**
     * @notice Emitted cuando se actualiza el router Uniswap (se proporciona router antiguo y nuevo).
     * @param oldRouter Router anterior.
     * @param newRouter Router nuevo.
     */
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);

    /**
     * @notice Emitted cuando se actualiza el slippage en bps.
     * @param oldBps Valor antiguo.
     * @param newBps Valor nuevo.
     */
    event SlippageUpdated(uint256 oldBps, uint256 newBps);

    /**
     * @notice Emitted cuando se actualiza el límite global del banco (bank cap).
     * @param oldCapUsd18 Valor antiguo (usd18).
     * @param newCapUsd18 Valor nuevo (usd18).
     */
    event BankCapUpdated(uint256 oldCapUsd18, uint256 newCapUsd18);

    /**
     * @notice Emitted cuando se actualiza el límite de retiro diario por usuario.
     * @param oldLimitUsd18 Valor antiguo (usd18).
     * @param newLimitUsd18 Valor nuevo (usd18).
     */
    event PerUserWithdrawLimitUpdated(uint256 oldLimitUsd18, uint256 newLimitUsd18);

    /**
     * @notice Emitted cuando el contrato se inicializa (constructor).
     * @param deployer Dirección que desplegó el contrato (se le asignan roles).
     * @param router Router configurado.
     * @param bankCapUsd18 Límite global inicial (usd18).
     * @param perUserLimitUsd18 Límite diario por usuario (usd18).
     */
    event ContractInitialized(address indexed deployer, address indexed router, uint256 bankCapUsd18, uint256 perUserLimitUsd18);

    /**
     * @notice Emitted cuando se transfiere saldo interno USDC de un usuario a otro.
     * @param from Remitente interno.
     * @param to Receptor interno.
     * @param amountUSDC Cantidad en USDC cruda transferida internamente.
     * @param timestamp Timestamp de la operación.
     */
    event TransferInternal(address indexed from, address indexed to, uint256 amountUSDC, uint256 timestamp);

    /**
     * @notice Emitted cuando un admin ajusta manualmente el total contabilizado (corrección).
     * @param deltaUsd18 Delta aplicado (puede ser negativo).
     * @param reason Razón textual para auditoría.
     */
    event AdminAdjustedTotal(int256 deltaUsd18, string reason);

    /**
     * @notice Emitted cuando se actualiza/establece un price feed para un token.
     * @param token Token afectado.
     * @param oldFeed Feed anterior (address(0) si ninguno).
     * @param newFeed Nuevo feed (address(0) para limpiar).
     */
    event PriceFeedUpdated(address indexed token, address indexed oldFeed, address indexed newFeed);

    // ============================
    // Errores personalizados (gas-friendly)
    // ============================
    error InvalidAmount(uint256 amount);
    error InvalidAddress(address addr);
    error BankCapExceeded(uint256 attempted, uint256 cap);
    error WithdrawLimitExceeded(uint256 attempted, uint256 limit);
    error InsufficientBalance(address user, uint256 requested, uint256 available);
    error SwapFailed(address fromToken, address toToken, uint256 amountIn);
    error NoUSDCpair(address token);
    error SlippageExceeded(uint256 expected, uint256 received);
    error Unauthorized();
    error UnexpectedFailure(string reason);

    // ============================
    // Constructor
    // ============================
    /**
     * @notice Inicializa el contrato estableciendo parámetros esenciales.
     * @param _bankCapUsd18 Límite global del banco (usd18).
     * @param _usdc Dirección del token USDC que se usará como moneda interna.
     * @param _uniswapRouter Dirección del router Uniswap V2 (IUniswapV2Router02).
     * @param _perUserDailyWithdrawLimitUsd18 Límite diario por usuario (usd18).
     *
     * @dev
     * - Valida que no se pasen direcciones nulas para parámetros críticos.
     * - Intenta leer factory y WETH del router (si el router los provee).
     * - Registra USDC en tokenRegistry (intenta leer decimals del token, fallback 6/18).
     * - Concede roles DEFAULT_ADMIN y demás al deployer msg.sender.
     */
    constructor(
        uint256 _bankCapUsd18,
        address _usdc,
        address _uniswapRouter,
        uint256 _perUserDailyWithdrawLimitUsd18
    ) {
        if (_bankCapUsd18 == 0 || _usdc == address(0) || _uniswapRouter == address(0)) revert InvalidAddress(address(0));

        bankCapUsd18 = _bankCapUsd18;
        USDC = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);

        address f;
        address w;
        try uniswapRouter.factory() returns (address factoryAddr) { f = factoryAddr; } catch { f = address(0); }
        try uniswapRouter.WETH() returns (address wethAddr) { w = wethAddr; } catch { w = address(0); }
        uniswapFactory = IUniswapV2Factory(f);
        WETH = w;

        // Registrar decimals de USDC si está disponible. Fall back si la llamada falla.
        uint8 usdcDec = 18;
        try IERC20Metadata(_usdc).decimals() returns (uint8 d) { usdcDec = d; } catch { usdcDec = 6; }
        tokenRegistry[_usdc].decimals = usdcDec;
        tokenRegistry[_usdc].enabled = true;

        perUserDailyWithdrawLimitUsd18 = _perUserDailyWithdrawLimitUsd18;

        // Conceder roles al deployer para administración inicial
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(RISK_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        emit ContractInitialized(msg.sender, _uniswapRouter, _bankCapUsd18, _perUserDailyWithdrawLimitUsd18);
    }

    // ============================
    // Modificadores de acceso
    // ============================
    /**
     * @notice Modificador que asegura que sólo ADMIN_ROLE puede ejecutar la función.
     * @dev Reemplaza require con revert personalizado para ahorrar gas y consistencia.
     */
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    // ============================
    // Configuración administrativa
    // ============================
    /**
     * @notice Establece el slippage en bps que se permite en los swaps.
     * @param newBps Nuevo valor en base-points (0..BPS_DENOMINATOR).
     * @dev Solo ADMIN_ROLE puede llamar. Revierta si newBps > BPS_DENOMINATOR.
     */
    function setSlippageBps(uint256 newBps) external onlyAdmin {
        if (newBps > BPS_DENOMINATOR) revert InvalidAmount(newBps);
        uint256 old = slippageBps;
        slippageBps = newBps;
        emit SlippageUpdated(old, newBps);
    }

    /**
     * @notice Actualiza el límite diario por usuario (usd18).
     * @param newLimitUsd18 Nuevo límite (usd18).
     * @dev Solo ADMIN_ROLE. 0 significa sin límite.
     */
    function setPerUserDailyWithdrawLimitUsd18(uint256 newLimitUsd18) external onlyAdmin {
        uint256 old = perUserDailyWithdrawLimitUsd18;
        perUserDailyWithdrawLimitUsd18 = newLimitUsd18;
        emit PerUserWithdrawLimitUpdated(old, newLimitUsd18);
    }

    /**
     * @notice Actualiza la máxima edad permitida del precio (si se usan feeds).
     * @param newMaxSeconds Nueva duración máxima en segundos.
     * @dev Solo RISK_ROLE. Afecta cómo podrían interpretarse feeds en futuras ampliaciones.
     */
    function setMaxPriceAgeSeconds(uint256 newMaxSeconds) external onlyRole(RISK_ROLE) {
        maxPriceAgeSeconds = newMaxSeconds;
    }

    /**
     * @notice Establece la lista de intermediarios a usar para construir rutas de swap.
     * @param list Arreglo de direcciones de tokens puente (puede incluir address(0) que se ignora).
     * @dev Solo ADMIN_ROLE. Reemplaza completamente la lista actual.
     */
    function setIntermediaries(address[] calldata list) external onlyAdmin {
        delete intermediaries;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(0)) continue;
            intermediaries.push(list[i]);
        }
    }

    /**
     * @notice Registra un token en tokenRegistry y opcionalmente su price feed.
     * @param token Dirección del token a registrar.
     * @param feed Dirección del AggregatorV3Interface (Chainlink) para ese token (address(0) para ninguno).
     * @param decimals Número de decimales del token (chequeo contra MAX_ALLOWED_TOKEN_DECIMALS).
     * @dev Solo ADMIN_ROLE. Marca el token como habilitado y guarda sus decimals.
     */
    function registerToken(address token, address feed, uint8 decimals) external onlyAdmin {
        if (token == address(0)) revert InvalidAddress(token);
        if (decimals > MAX_ALLOWED_TOKEN_DECIMALS) revert InvalidAmount(decimals);
        tokenRegistry[token] = TokenInfo({ enabled: true, decimals: decimals, totalDeposited: 0, totalConvertedUsd18: 0 });
        if (feed != address(0)) priceFeeds[token] = AggregatorV3Interface(feed);
        emit TokenStatusChanged(token, true);
    }

    /**
     * @notice Actualiza el router Uniswap usado para calcular rutas y ejecutar swaps.
     * @param newRouter Dirección del nuevo router.
     * @dev Solo ADMIN_ROLE. Intenta leer factory y WETH del nuevo router; emite RouterUpdated.
     */
    function setUniswapRouter(address newRouter) external onlyAdmin {
        if (newRouter == address(0)) revert InvalidAddress(newRouter);
        address old = address(uniswapRouter);
        uniswapRouter = IUniswapV2Router02(newRouter);
        address f;
        address w;
        try uniswapRouter.factory() returns (address factoryAddr) { f = factoryAddr; } catch { f = address(0); }
        try uniswapRouter.WETH() returns (address wethAddr) { w = wethAddr; } catch { w = address(0); }
        uniswapFactory = IUniswapV2Factory(f);
        WETH = w;
        emit RouterUpdated(old, newRouter);
    }

    /**
     * @notice Actualiza el límite global del banco (bankCapUsd18).
     * @param newBankCapUsd18 Nuevo límite (usd18).
     * @dev Solo ADMIN_ROLE. Emite evento con el antiguo y nuevo valor.
     */
    function setBankCapUsd18(uint256 newBankCapUsd18) external onlyAdmin {
        uint256 old = bankCapUsd18;
        bankCapUsd18 = newBankCapUsd18;
        emit BankCapUpdated(old, newBankCapUsd18);
    }

    /**
     * @notice Ajuste manual del contador totalDepositedUsd18 por parte del admin.
     * @param deltaUsd18 Delta firmado que se aplica al total (puede ser negativo).
     * @param reason Breve string con la razón del ajuste para auditoría.
     *
     * @dev Solo ADMIN_ROLE. Usado para correcciones contables. Si delta es positivo verifica que no se
     * exceda bankCapUsd18. Si delta es negativo reduce totalDepositedUsd18 hasta 0 sin underflow.
     */
    function adminAdjustTotalUsd18(int256 deltaUsd18, string calldata reason) external onlyRole(ADMIN_ROLE) {
        if (deltaUsd18 < 0) {
            uint256 abs = uint256(-deltaUsd18);
            if (abs >= totalDepositedUsd18) {
                totalDepositedUsd18 = 0;
            } else {
                totalDepositedUsd18 -= abs;
            }
        } else {
            totalDepositedUsd18 += uint256(deltaUsd18);
            if (totalDepositedUsd18 > bankCapUsd18) revert BankCapExceeded(totalDepositedUsd18, bankCapUsd18);
        }
        emit AdminAdjustedTotal(deltaUsd18, reason);
    }

    /**
     * @notice Actualiza la dirección del price feed para un token.
     * @param token Token a actualizar.
     * @param newFeed Nueva dirección del AggregatorV3Interface (address(0) para borrar).
     * @dev Solo RISK_ROLE. Actualiza mapping priceFeeds y emite evento.
     */
    function updatePriceFeed(address token, address newFeed) external onlyRole(RISK_ROLE) {
        AggregatorV3Interface old = priceFeeds[token];
        priceFeeds[token] = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(token, address(old), newFeed);
    }

    // ============================
    // Depósitos
    // ============================
    /**
     * @notice Deposita ETH y lo convierte a USDC inmediatamente (swap vía router).
     * @dev El usuario envía ETH con la llamada; la función llama a _depositCore con isETH=true.
     *      Requiere that contract is not paused y protege contra reentrancy.
     */
    function depositETH() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert InvalidAmount(0);
        _depositCore(ETH_ADDRESS, msg.value, true);
    }

    /**
     * @notice Deposita un token ERC20. Si el token es USDC se registra directamente; si no se intenta swap a USDC.
     * @param token Dirección del token a depositar (no usar address(0) para ERC20).
     * @param amount Cantidad a transferir desde msg.sender (unidades crudas del token).
     *
     * @dev La función:
     *  - Autoregistra decimals y habilita el token si no estaba registrado (y valida que pueda rutearse).
     *  - Usa balanceBefore/after para soportar tokens con fees on transfer.
     *  - Hace safeTransferFrom para traer tokens al contrato.
     *  - Llama a _depositCoreWithReceived con la cantidad realmente recibida.
     */
    function depositToken(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert InvalidAmount(0);
        if (token == ETH_ADDRESS) revert InvalidAddress(token);

        // Si el token no está habilitado, intentamos construir y validar la ruta primero.
        if (!tokenRegistry[token].enabled) {
            _buildAndValidatePath(token, false);
            uint8 dec = 18;
            try IERC20Metadata(token).decimals() returns (uint8 d) { dec = d; } catch { dec = 18; }
            tokenRegistry[token].decimals = dec;
            tokenRegistry[token].enabled = true;
            emit TokenStatusChanged(token, true);
        }

        // Medimos cantidad realmente recibida para soportar tokens con fees.
        IERC20 tokenContract = IERC20(token);
        uint256 balanceBefore = tokenContract.balanceOf(address(this));
        tokenContract.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balanceAfter = tokenContract.balanceOf(address(this));
        uint256 received = balanceAfter - balanceBefore;
        if (received == 0) revert InvalidAmount(0);

        _depositCoreWithReceived(token, received, false);
    }

    /**
     * @notice Lógica central de depósito que acepta la cantidad ya recibida (para tokens fee-on-transfer).
     * @param token Dirección del token (o USDC o ETH_ADDRESS).
     * @param receivedAmount Cantidad realmente recibida (en unidades crudas del token, o ETH wei).
     * @param isETH Indica si el depósito fue ETH.
     *
     * @dev Si token == USDC => se registra directamente.
     *      Si no => se construye ruta, calcula expected out vía getAmountsOut, determina amountOutMin según slippage,
     *               ejecuta swap y mide USDC recibido con balanceBefore/after.
     *      Luego convierte USDC raw a usd18 (por decimales), valida contra bankCap y actualiza estructuras:
     *         - tokenRegistry totals
     *         - userDeposits[msg.sender][token]
     *         - userUSDCBalance[msg.sender]
     *         - totalDepositedUsd18 y accounting
     *      Emite DepositMade y SwapExecuted cuando aplica.
     */
    function _depositCoreWithReceived(address token, uint256 receivedAmount, bool isETH) internal {
        uint256 usdcRawReceived;

        if (token == USDC) {
            // Depósito directo de USDC: la cantidad recibida ya está en unidades USDC crudas.
            usdcRawReceived = receivedAmount;
        } else {
            address[] memory path = _buildAndValidatePath(token, isETH);

            // Intentamos estimar el output esperado usando getAmountsOut
            uint256[] memory amountsOut;
            try uniswapRouter.getAmountsOut(receivedAmount, path) returns (uint256[] memory ao) {
                amountsOut = ao;
            } catch {
                revert SwapFailed(token, USDC, receivedAmount);
            }

            uint256 expected = amountsOut[amountsOut.length - 1];
            uint256 amountOutMin = (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

            // Medimos USDC antes/después del swap para soportar variaciones y tokens con transfer hooks.
            uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

            if (isETH) {
                try uniswapRouter.swapExactETHForTokens{value: receivedAmount}(amountOutMin, path, address(this), block.timestamp + 300) {
                } catch {
                    revert SwapFailed(ETH_ADDRESS, USDC, receivedAmount);
                }
            } else {
                // Asegurar allowance dada la posibilidad de tokens no-estándar.
                _ensureAllowance(IERC20(token), address(uniswapRouter), receivedAmount);

                try uniswapRouter.swapExactTokensForTokens(receivedAmount, amountOutMin, path, address(this), block.timestamp + 300) {
                } catch {
                    revert SwapFailed(token, USDC, receivedAmount);
                }
            }

            uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
            usdcRawReceived = usdcAfter - usdcBefore;

            // Comprobación extra de slippage: si recibimos menos que el mínimo esperado, revertir.
            if (usdcRawReceived < amountOutMin) revert SlippageExceeded(expected, usdcRawReceived);
            emit SwapExecuted(isETH ? address(0) : token, USDC, receivedAmount, usdcRawReceived);
        }

        // Convertir USDC (raw) a usd18 usando decimales del token USDC registrado.
        uint256 usd18 = _toUsd18(USDC, usdcRawReceived);

        // Chequear el límite global del banco antes de aceptar el depósito.
        if (totalDepositedUsd18 + usd18 > bankCapUsd18) revert BankCapExceeded(totalDepositedUsd18 + usd18, bankCapUsd18);

        // Actualizar registros del token (para auditoría)
        tokenRegistry[token].totalDeposited += (token == USDC) ? usdcRawReceived : receivedAmount;
        tokenRegistry[token].totalConvertedUsd18 += usd18;

        // Actualizar depósito individual del usuario
        DepositInfo storage di = userDeposits[msg.sender][token];
        di.amountToken += (token == USDC) ? usdcRawReceived : receivedAmount;
        di.amountUSDC += usdcRawReceived;
        di.lastDeposit = block.timestamp;

        // Actualizar balance USDC interno y contabilidad global
        userUSDCBalance[msg.sender] += usdcRawReceived;
        totalDepositedUsd18 += usd18;

        BankAccounting storage acc = accounting;
        acc.totalDepositsUsd18 += usd18;
        acc.totalConvertedUSDC += usdcRawReceived;
        acc.totalSwapsExecuted += (token == USDC ? 0 : 1);
        acc.lastUpdateTimestamp = block.timestamp;

        emit DepositMade(msg.sender, token, (token == USDC) ? usdcRawReceived : receivedAmount, usdcRawReceived, block.timestamp);
    }

    /**
     * @notice Pequeño wrapper que mantiene la compatibilidad con el flujo original de depósitos.
     * @dev Llama a _depositCoreWithReceived con el amount proporcionado.
     */
    function _depositCore(address token, uint256 amount, bool isETH) internal {
        _depositCoreWithReceived(token, amount, isETH);
    }

    // ============================
    // Construcción y validación de rutas
    // ============================
    /**
     * @notice Construye una ruta de swap desde `token` hacia USDC.
     * @param token Token origen (address(0) si isETH==true).
     * @param isETH Indicador si la entrada es ETH.
     * @return Una ruta (array de direcciones) utilizable por IUniswapV2Router02.
     *
     * @dev La función intenta, en orden:
     *  - Si es ETH: usar [WETH, USDC]
     *  - Si existe par (token, USDC) en factory: [token, USDC]
     *  - Si existe (token, WETH) y (WETH, USDC): [token, WETH, USDC]
     *  - Probar cada "intermediario" configurado: [token, mid, USDC] y validar getAmountsOut con amount=1
     *  - Si no se encuentra ruta, revert con NoUSDCpair(token)
     */
    function _buildAndValidatePath(address token, bool isETH) internal view returns (address[] memory) {
        if (isETH) {
            if (WETH == address(0)) revert NoUSDCpair(token);
            address[] memory pETH = new address[](2);
            pETH[0] = WETH;
            pETH[1] = USDC;
            return pETH;
        }

        if (address(uniswapFactory) != address(0)) {
            address p = uniswapFactory.getPair(token, USDC);
            if (p != address(0)) {
                address[] memory p2 = new address[](2);
                p2[0] = token;
                p2[1] = USDC;
                return p2;
            }

            if (WETH != address(0)) {
                address p1 = uniswapFactory.getPair(token, WETH);
                address p2a = uniswapFactory.getPair(WETH, USDC);
                if (p1 != address(0) && p2a != address(0)) {
                    address[] memory p3 = new address[](3);
                    p3[0] = token;
                    p3[1] = WETH;
                    p3[2] = USDC;
                    return p3;
                }
            }
        }

        // Intentar intermediarios configurados por admin
        for (uint256 i = 0; i < intermediaries.length; i++) {
            address mid = intermediaries[i];
            if (mid == address(0)) continue;
            if (address(uniswapFactory) != address(0)) {
                if (uniswapFactory.getPair(token, mid) == address(0) || uniswapFactory.getPair(mid, USDC) == address(0)) continue;
            }
            address[] memory candidate = new address[](3);
            candidate[0] = token;
            candidate[1] = mid;
            candidate[2] = USDC;
            try uniswapRouter.getAmountsOut(1, candidate) returns (uint256[] memory) {
                return candidate;
            } catch {
                continue;
            }
        }

        revert NoUSDCpair(token);
    }

    // ============================
    // Retiros
    // ============================
    /**
     * @notice Permite a un usuario retirar sus fondos internos en USDC (transferir USDC fuera del sistema).
     * @param usdcRawAmount Cantidad en unidades crudas de USDC a retirar.
     *
     * @dev Comprueba:
     *  - monto > 0
     *  - usuario tiene balance suficiente en userUSDCBalance
     *  - el retiro no viola el límite diario por usuario (usd18)
     *  - actualiza totalDepositedUsd18 y contabilidad
     *  - transfiere USDC al usuario con safeTransfer (uso de SafeERC20)
     */
    function withdraw(uint256 usdcRawAmount) external whenNotPaused nonReentrant {
        if (usdcRawAmount == 0) revert InvalidAmount(0);
        uint256 bal = userUSDCBalance[msg.sender];
        if (usdcRawAmount > bal) revert InsufficientBalance(msg.sender, usdcRawAmount, bal);

        uint256 usd18 = _toUsd18(USDC, usdcRawAmount);
        _consumeWithdrawLimit(msg.sender, usd18);

        userUSDCBalance[msg.sender] = bal - usdcRawAmount;
        if (totalDepositedUsd18 <= usd18) totalDepositedUsd18 = 0;
        else totalDepositedUsd18 -= usd18;

        accounting.totalWithdrawalsUsd18 += usd18;
        accounting.lastUpdateTimestamp = block.timestamp;

        IERC20(USDC).safeTransfer(msg.sender, usdcRawAmount);
        emit WithdrawalMade(msg.sender, USDC, usdcRawAmount, block.timestamp);
    }

    /**
     * @notice Transfiere internamente saldo USDC de un usuario a otro sin mover tokens en la cadena.
     * @param to Dirección destino (no address(0)).
     * @param usdcRawAmount Cantidad a transferir (unidades crudas USDC).
     *
     * @dev Actualiza userUSDCBalance de emisor y receptor y emite TransferInternal.
     */
    function transferInternal(address to, uint256 usdcRawAmount) external whenNotPaused nonReentrant {
        if (to == address(0)) revert InvalidAddress(to);
        if (usdcRawAmount == 0) revert InvalidAmount(0);
        uint256 balance = userUSDCBalance[msg.sender];
        if (usdcRawAmount > balance) revert InsufficientBalance(msg.sender, usdcRawAmount, balance);

        userUSDCBalance[msg.sender] = balance - usdcRawAmount;
        userUSDCBalance[to] += usdcRawAmount;

        emit TransferInternal(msg.sender, to, usdcRawAmount, block.timestamp);
    }

    // ============================
    // Helpers y utilidades
    // ============================
    /**
     * @notice Asegura que el contrato tenga allowance suficiente hacia `spender` para el token dado.
     * @param tokenContract Interfaz IERC20 del token.
     * @param spender Dirección que necesita la allowance (p. ej. router).
     * @param amount Cantidad requerida.
     *
     * @dev Intenta llamar approve de forma estándar. Si falla, usa llamadas a bajo nivel para manejar tokens no convencionales.
     */
    function _ensureAllowance(IERC20 tokenContract, address spender, uint256 amount) internal {
        uint256 current = tokenContract.allowance(address(this), spender);
        if (current >= amount) return;

        // Intentar approve estándar
        try tokenContract.approve(spender, amount) {
            return;
        } catch {
            // Si falla, hacer secuencia approve(0) y approve(amount) con llamadas low-level para maximizar compatibilidad.
            if (current != 0) {
                (bool ok0, bytes memory ret0) = address(tokenContract).call(abi.encodeWithSelector(tokenContract.approve.selector, spender, 0));
                require(ok0 && (ret0.length == 0 || abi.decode(ret0, (bool))), "approve(0) failed");
            }
            (bool ok1, bytes memory ret1) = address(tokenContract).call(abi.encodeWithSelector(tokenContract.approve.selector, spender, amount));
            require(ok1 && (ret1.length == 0 || abi.decode(ret1, (bool))), "approve(amount) failed");
        }
    }

    /**
     * @notice Convierte una cantidad cruda de `token` a la representación usd18 (18 decimales).
     * @param token Dirección del token (debe estar registrado o permitir lectura de decimals()).
     * @param rawAmount Cantidad en unidades crudas del token.
     * @return uint256 Cantidad convertida a 18 decimales (usd18).
     *
     * @dev - Si token tiene 18 decimales, se retorna rawAmount sin cambios.
     *      - Si tiene menos de 18, multiplica por 10^(18-dec).
     *      - Si tiene más de 18, divide por 10^(dec-18) truncando.
     *      - Busca decimales en tokenRegistry o consulta IERC20Metadata como fallback.
     */
    function _toUsd18(address token, uint256 rawAmount) internal view returns (uint256) {
        uint8 dec = tokenRegistry[token].decimals;
        if (dec == 0) {
            try IERC20Metadata(token).decimals() returns (uint8 d) { dec = d; } catch { dec = 18; }
        }
        if (dec == 18) return rawAmount;
        else if (dec < 18) return rawAmount * (10 ** (18 - dec));
        else return rawAmount / (10 ** (dec - 18));
    }

    /**
     * @notice Consume parte o la totalidad del límite diario del usuario al retirar.
     * @param user Dirección del usuario.
     * @param usd18 Cantidad en usd18 a consumir.
     *
     * @dev - Si el límite por usuario es 0, no realiza comprobaciones.
     *      - Mantiene una ventana diaria basada en start-of-day (UTC) y acumulador spentUsd18.
     *      - Si la suma excede el límite, revierte con WithdrawLimitExceeded.
     */
    function _consumeWithdrawLimit(address user, uint256 usd18) internal {
        uint256 limit = perUserDailyWithdrawLimitUsd18;
        if (limit == 0) return;
        (uint64 currentStart, ) = _currentDay();
        WithdrawWindow storage w = _userWithdrawWindow[user];
        if (w.windowStart != currentStart) {
            w.windowStart = currentStart;
            w.spentUsd18 = 0;
        }
        uint256 newSpent = uint256(w.spentUsd18) + usd18;
        if (newSpent > limit) revert WithdrawLimitExceeded(newSpent, limit);
        w.spentUsd18 = uint192(newSpent);
    }

    /**
     * @notice Calcula el inicio de la "jornada" actual (start-of-day) y la duración de la ventana.
     * @return start Timestamp del inicio del día (UTC).
     * @return window Duración fija (86400 segundos).
     *
     * @dev Usado para la lógica de límites diarios.
     */
    function _currentDay() internal view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    // ============================
    // Vistas / Utilidades públicas
    // ============================
    /**
     * @notice Indica si este contrato "soporta" un token (si puede rutearlo a USDC o es USDC).
     * @param token Dirección del token a verificar.
     * @return bool True si token == USDC o está registrado habilitado o si _canRoute devuelve true.
     *
     * @dev Implementado para proporcionar una verificación rápida desde fuera.
     */
    function supportsToken(address token) external view returns (bool) {
        if (token == USDC) return true;
        if (tokenRegistry[token].enabled) return true;
        try this._canRoute(token) returns (bool ok) { return ok; } catch { return false; }
    }

    /**
     * @notice Chequeo interno usado por supportsToken para verificar capacidad de enrutamiento.
     * @param token Token a comprobar.
     * @return bool True si la factory indica pares directos o vía WETH.
     */
    function _canRoute(address token) external view returns (bool) {
        if (address(uniswapFactory) == address(0)) return false;
        if (uniswapFactory.getPair(token, USDC) != address(0)) return true;
        if (WETH != address(0) && uniswapFactory.getPair(token, WETH) != address(0) && uniswapFactory.getPair(WETH, USDC) != address(0)) return true;
        return false;
    }

    /**
     * @notice Devuelve el balance interno USDC de un usuario (unidades crudas).
     * @param user Dirección del usuario.
     * @return uint256 Balance en USDC crudo.
     */
    function getUserUSDCBalance(address user) external view returns (uint256) {
        return userUSDCBalance[user];
    }

    // ============================
    // Emergencias / recuperación
    // ============================
    /**
     * @notice Permite al admin rescatar tokens (excepto USDC) o ETH cuando el contrato está pausado.
     * @param token Dirección del token a rescatar (address(0) para ETH).
     * @param to Dirección destino que recibirá los fondos.
     * @param amount Cantidad a enviar (wei para ETH, unidades crudas para ERC20).
     *
     * @dev - Solo ADMIN_ROLE y solo cuando el contrato está pausado.
     *      - No permite retirar USDC para evitar evadir la contabilidad interna.
     *      - Emite RouterUpdated como una señal ligera (históricamente utilizado en este contrato).
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ADMIN_ROLE) whenPaused nonReentrant {
        if (to == address(0)) revert InvalidAddress(to);
        if (amount == 0) revert InvalidAmount(0);
        if (token == USDC) revert UnexpectedFailure("Cannot withdraw USDC via emergency");
        if (token == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert UnexpectedFailure("ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        // Reusar RouterUpdated como señal de rescate (ligera; no semánticamente relacionado).
        emit RouterUpdated(address(0), address(0));
    }
}
