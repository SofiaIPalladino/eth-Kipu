// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;


import "lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import "lib/openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import "lib/openzeppelin-contracts/contracts/security/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "lib/chainlink-evm/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "lib/uniswap-v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title KipuBankV3
 * @author Sofía Isabella Palladino
 * @notice Banco descentralizado multi-token con swaps automáticos a USDC
 * @dev Mejora de KipuBankV2 integrando Uniswap V2 y control estricto de Bank Cap
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ==================== ROLES ====================
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");

    // ==================== CONSTANTES ====================
    address public constant ETH_ADDRESS = address(0);
    uint8 public constant MAX_ALLOWED_TOKEN_DECIMALS = 36;
    uint256 private constant USD18_SCALE = 1e18;

    // ==================== VARIABLES ====================
    uint256 public immutable bankCapUsd18;   // límite máximo en USDC18
    uint256 public totalDepositedUsd18;      // total depositado en USD18
    uint256 public perUserDailyWithdrawLimitUsd18;

    // Token management
    mapping(address => bool) public supportedTokens;
    mapping(address => uint8) public tokenDecimals; 
    mapping(address => AggregatorV3Interface) public priceFeeds;

    // User balances (todas las operaciones se acreditan en USDC)
    mapping(address => uint256) public balances; 

    // Withdraw window
    struct WithdrawWindow { uint64 windowStart; uint192 spentUsd18; }
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // Uniswap V2 Router
    IUniswapV2Router02 public immutable uniswapRouter;
    address public immutable USDC; // USDC token address

    uint256 public maxPriceAgeSeconds = 24 hours;

    // ==================== EVENTOS ====================
    event Deposit(address indexed user, address indexed token, uint256 amountRaw, uint256 valueUsd18);
    event Withdrawal(address indexed user, uint256 amountUsd18);
    event InternalTransfer(address indexed from, address indexed to, uint256 amountUsd18);
    event TokenAdded(address indexed token, address indexed priceFeed, uint8 decimals);

    // ==================== ERRORES ====================
    error InvalidAmount();
    error InvalidAddress();
    error TokenNotSupported();
    error BankCapExceeded();
    error TransferFailed();
    error WithdrawLimitExceeded();
    error DecimalsTooLarge();

    // ==================== MODIFICADORES ====================
    modifier onlyValidAmount(uint256 amount) {
        if (amount == 0) revert InvalidAmount();
        _;
    }

    modifier onlySupportedToken(address token) {
        if (!supportedTokens[token]) revert TokenNotSupported();
        _;
    }

    modifier enforceBankCap(uint256 usd18Amount) {
        if (totalDepositedUsd18 + usd18Amount > bankCapUsd18) revert BankCapExceeded();
        _;
    }

    // ==================== CONSTRUCTOR ====================
    constructor(
        uint256 _bankCapUsd18,
        address _usdc,
        address _uniswapRouter,
        uint256 _perUserDailyWithdrawLimitUsd18
    ) {
        if (_bankCapUsd18 == 0 || _usdc == address(0) || _uniswapRouter == address(0)) revert InvalidAddress();

        bankCapUsd18 = _bankCapUsd18;
        USDC = _usdc;
        uniswapRouter = IUniswapV2Router02(_uniswapRouter);
        perUserDailyWithdrawLimitUsd18 = _perUserDailyWithdrawLimitUsd18;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(RISK_ROLE, msg.sender);
    }

    // ==================== TOKEN REGISTRATION ====================
    function registerToken(address token, address feed, uint8 decimals) external onlyRole(ADMIN_ROLE) {
        if (token == address(0) || feed == address(0)) revert InvalidAddress();
        if (decimals > MAX_ALLOWED_TOKEN_DECIMALS) revert DecimalsTooLarge();

        supportedTokens[token] = true;
        tokenDecimals[token] = decimals;
        priceFeeds[token] = AggregatorV3Interface(feed);

        emit TokenAdded(token, feed, decimals);
    }

    // ==================== DEPOSIT ====================
    function depositETH() external payable whenNotPaused nonReentrant onlyValidAmount(msg.value) {
        _depositToken(ETH_ADDRESS, msg.value, true);
    }

    function depositToken(address token, uint256 amountRaw)
        external whenNotPaused nonReentrant onlyValidAmount(amountRaw) onlySupportedToken(token)
    {
        if (token == ETH_ADDRESS) revert InvalidAddress();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountRaw);
        _depositToken(token, amountRaw, false);
    }

    // ==================== INTERNAL DEPOSIT & SWAP ====================
    function _depositToken(address token, uint256 amount, bool isETH) internal enforceBankCap(0) {
        uint256 usdcAmount;

        if (token == USDC) {
            usdcAmount = amount;
        } else {
            if (isETH) {
                address ;
                path[0] = uniswapRouter.WETH();
                path[1] = USDC;
                uint256[] memory amounts = uniswapRouter.swapExactETHForTokens{value: amount}(
                    0,
                    path,
                    address(this),
                    block.timestamp
                );
                usdcAmount = amounts[amounts.length - 1];
            } else {
                IERC20(token).safeApprove(address(uniswapRouter), amount);
                address ;
                path[0] = token;
                path[1] = USDC;
                uint256[] memory amounts = uniswapRouter.swapExactTokensForTokens(
                    amount,
                    0,
                    path,
                    address(this),
                    block.timestamp
                );
                usdcAmount = amounts[amounts.length - 1];
            }
        }

        if (totalDepositedUsd18 + usdcAmount > bankCapUsd18) revert BankCapExceeded();

        balances[msg.sender] += usdcAmount;
        totalDepositedUsd18 += usdcAmount;

        emit Deposit(msg.sender, token, amount, usdcAmount);
    }

    // ==================== WITHDRAW ====================
    function withdraw(uint256 usdcAmount) external whenNotPaused nonReentrant onlyValidAmount(usdcAmount) {
        if (balances[msg.sender] < usdcAmount) revert WithdrawLimitExceeded();
        _consumeWithdrawLimit(msg.sender, usdcAmount);

        balances[msg.sender] -= usdcAmount;
        totalDepositedUsd18 -= usdcAmount;

        IERC20(USDC).safeTransfer(msg.sender, usdcAmount);
        emit Withdrawal(msg.sender, usdcAmount);
    }

    // ==================== INTERNAL TRANSFER ====================
    function transferInternal(address to, uint256 usdcAmount)
        external whenNotPaused nonReentrant onlyValidAmount(usdcAmount)
    {
        if (to == address(0)) revert InvalidAddress();
        if (balances[msg.sender] < usdcAmount) revert InsufficientBalance();

        balances[msg.sender] -= usdcAmount;
        balances[to] += usdcAmount;

        emit InternalTransfer(msg.sender, to, usdcAmount);
    }

    // ==================== WITHDRAW LIMIT ====================
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
        if (newSpent > limit) revert WithdrawLimitExceeded();
        w.spentUsd18 = uint192(newSpent);
    }

    function _currentDay() internal view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    // ==================== PAUSE ====================
    function pause() external onlyRole(OPERATOR_ROLE) { _pause(); }
    function unpause() external onlyRole(OPERATOR_ROLE) { _unpause(); }

    // ==================== RECEIVE / FALLBACK ====================
    receive() external payable { revert("Use depositETH()"); }
    fallback() external payable { revert("Function does not exist"); }
}
