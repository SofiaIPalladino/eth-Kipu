// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title KipuBank
 * @dev Contrato de bóveda de tokens nativos (ETH) con límites de depósito y retiro.
 * Implementa control de límite global (bankCap) usando una variable de estado interna.
 */
contract KipuBank {

    // Custom Errors

    /// @dev Se lanza si el depósito total excede el límite global del banco (bankCap).
    error DepositLimitExceeded(uint256 bankCap, uint256 currentBalance, uint256 depositAmount);
    /// @dev Se lanza si la cantidad de retiro excede el umbral por transacción (withdrawalThreshold).
    error WithdrawalThresholdExceeded(uint256 threshold, uint256 amount);
    /// @dev Se lanza si el usuario intenta retirar más de su saldo disponible.
    error InsufficientFunds(uint256 required, uint256 available);
    /// @dev Se lanza si la cantidad de la transacción es cero.
    error ZeroAmount();
    /// @dev Se lanza si la transferencia de ETH nativo al usuario falla.
    error TransferFailed();


   
    // Events

    /// @dev Se emite cuando un usuario deposita fondos con éxito.
    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    /// @dev Se emite cuando un usuario retira fondos con éxito.
    event Withdrawal(address indexed user, uint256 amount, uint256 newBalance);


   

    // State Variables

    // Variables Immutable
    /// @dev Límite global del monto total que el banco puede contener.
    uint256 public immutable bankCap;
    /// @dev Límite máximo de retiro por transacción.
    uint256 public immutable withdrawalThreshold;

    // Mapping
    /// @dev Almacena el saldo de ETH de cada usuario. (Requisito: al menos un mapping)
    mapping(address => uint256) private balances;

    // Conteo
    /// @dev Contador del número total de depósitos realizados.
    uint256 public totalDeposits;
    /// @dev Contador del número total de retiros realizados.
    uint256 public totalWithdrawals;
    /// @dev Balance total de ETH depositado por usuarios a través de la función deposit().
    uint256 private totalBankBalance; 




  
    // Constructor

    /**
     * @dev Constructor que establece los límites inmutables del banco.
     * @param _bankCap El límite máximo de ETH que el contrato puede contener.
     * @param _withdrawalThreshold El máximo de ETH que un usuario puede retirar por transacción.
     */
    constructor(uint256 _bankCap, uint256 _withdrawalThreshold) {
        if (_bankCap == 0 || _withdrawalThreshold == 0) {
            revert ZeroAmount();
        }
        bankCap = _bankCap;
        withdrawalThreshold = _withdrawalThreshold;
    }



    
    // Modifier
    /**
     * @dev Asegura que el valor enviado sea mayor que cero.
     */
    modifier nonZeroValue() {
        if (msg.value == 0) {
            revert ZeroAmount();
        }
        _;
    }


    
    // Functions
    // =============================

    // --- FUNCIÓN EXTERNAL PAYABLE ---
    /**
     * @dev Permite a los usuarios depositar ETH. Aplica el límite global (bankCap).
     */
    function deposit() external payable nonZeroValue {
        uint256 amount = msg.value;
        
        // Checks (Patrón CEI)
        uint256 newTotal = totalBankBalance + amount;
        if (newTotal > bankCap) {
            // Se usa el balance controlado, no address(this).balance
            revert DepositLimitExceeded(bankCap, totalBankBalance, amount);
        }

        // Effects
        balances[msg.sender] += amount;
        totalBankBalance = newTotal; // Actualiza el balance total controlado
        totalDeposits++;
        uint256 newBalance = balances[msg.sender];

        // Interactions
        emit Deposit(msg.sender, amount, newBalance);
    }

    // --- FUNCIÓN EXTERNAL ---
    /**
     * @dev Permite al usuario retirar fondos. Aplica el límite por transacción (withdrawalThreshold) y el patrón CEI.
     * @param _amount La cantidad de ETH a retirar.
     */
    function withdraw(uint256 _amount) external {
        // Checks
        if (_amount == 0) {
            revert ZeroAmount();
        }
        if (_amount > withdrawalThreshold) {
            revert WithdrawalThresholdExceeded(withdrawalThreshold, _amount);
        }
        if (_amount > balances[msg.sender]) {
            revert InsufficientFunds(_amount, balances[msg.sender]);
        }
        
        // Effects
        balances[msg.sender] -= _amount;
        totalBankBalance -= _amount; // Reduce el balance total controlado
        totalWithdrawals++;
        uint256 newBalance = balances[msg.sender];

        // Interactions
        (bool success, ) = payable(msg.sender).call{value: _amount}("");
        if (!success) {
            // Rollback de todos los efectos si la transferencia falla
            balances[msg.sender] += _amount;
            totalBankBalance += _amount;
            revert TransferFailed();
        }

        emit Withdrawal(msg.sender, _amount, newBalance);
    }

    // --- FUNCIÓN PRIVATE ---
    /**
     * @dev Función interna para validar si un usuario tiene saldo positivo (cumple requisito 'private').
     * @param _user La dirección a verificar.
     * @return true si el saldo es positivo.
     */
    function _hasPositiveBalance(address _user) private view returns (bool) {
        return balances[_user] > 0;
    }

    // --- FUNCIÓN EXTERNAL VIEW ---
    /**
     * @dev Devuelve el saldo actual de ETH del usuario (cumple requisito 'external view').
     * @param _user La dirección del usuario.
     * @return El saldo de ETH del usuario.
     */
    function getBalance(address _user) external view returns (uint256) {
        return balances[_user];
    }
}