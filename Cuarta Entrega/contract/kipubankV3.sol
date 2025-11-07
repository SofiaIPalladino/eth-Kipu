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
 */
contract KipuBankV3 is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant RISK_ROLE = keccak256("RISK_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    // Constants
    address public constant ETH_ADDRESS = address(0);
    uint8 public constant MAX_ALLOWED_TOKEN_DECIMALS = 36;
    uint16 public constant BPS_DENOMINATOR = 10000;

    // State
    // bankCap is now mutable (admin can change it); stored in USD18 units
    uint256 public bankCapUsd18;
    uint256 public totalDepositedUsd18;
    uint256 public perUserDailyWithdrawLimitUsd18;

    IUniswapV2Router02 public uniswapRouter;
    IUniswapV2Factory public uniswapFactory;
    address public WETH;
    address public immutable USDC;

    uint256 public slippageBps = 500;
    uint256 public maxPriceAgeSeconds = 24 hours;

    address[] public intermediaries;

    struct TokenInfo {
        bool enabled;
        uint8 decimals;
        uint256 totalDeposited; // actual token units received
        uint256 totalConvertedUsd18;
    }

    struct DepositInfo {
        uint256 amountToken; // actual token units received
        uint256 amountUSDC;  // raw USDC units received from conversion
        uint256 lastDeposit;
    }

    struct BankAccounting {
        uint256 totalDepositsUsd18;
        uint256 totalWithdrawalsUsd18;
        uint256 totalSwapsExecuted;
        uint256 totalConvertedUSDC;
        uint256 lastUpdateTimestamp;
    }

    BankAccounting public accounting;

    mapping(address => TokenInfo) public tokenRegistry;
    mapping(address => mapping(address => DepositInfo)) public userDeposits;
    mapping(address => uint256) public userUSDCBalance; // raw USDC units per user

    // optional price feeds
    mapping(address => AggregatorV3Interface) public priceFeeds;

    struct WithdrawWindow { uint64 windowStart; uint192 spentUsd18; }
    mapping(address => WithdrawWindow) private _userWithdrawWindow;

    // Events
    event DepositMade(address indexed user, address indexed token, uint256 amountToken, uint256 amountUSDC, uint256 timestamp);
    event WithdrawalMade(address indexed user, address indexed token, uint256 amountUSDC, uint256 timestamp);
    event SwapExecuted(address indexed fromToken, address indexed toToken, uint256 amountIn, uint256 amountOut);
    event TokenStatusChanged(address indexed token, bool enabled);
    event RouterUpdated(address indexed oldRouter, address indexed newRouter);
    event SlippageUpdated(uint256 oldBps, uint256 newBps);
    event BankCapUpdated(uint256 oldCapUsd18, uint256 newCapUsd18);
    event PerUserWithdrawLimitUpdated(uint256 oldLimitUsd18, uint256 newLimitUsd18);
    event ContractInitialized(address indexed deployer, address indexed router, uint256 bankCapUsd18, uint256 perUserLimitUsd18);
    event TransferInternal(address indexed from, address indexed to, uint256 amountUSDC, uint256 timestamp);

    // Added events for adminAdjustTotal & price feed changes
    event AdminAdjustedTotal(int256 deltaUsd18, string reason);
    event PriceFeedUpdated(address indexed token, address indexed oldFeed, address indexed newFeed);

    // Errors
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

        // register USDC decimals if available
        uint8 usdcDec = 18;
        try IERC20Metadata(_usdc).decimals() returns (uint8 d) { usdcDec = d; } catch { usdcDec = 6; }
        tokenRegistry[_usdc].decimals = usdcDec;
        tokenRegistry[_usdc].enabled = true;

        perUserDailyWithdrawLimitUsd18 = _perUserDailyWithdrawLimitUsd18;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(RISK_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);

        emit ContractInitialized(msg.sender, _uniswapRouter, _bankCapUsd18, _perUserDailyWithdrawLimitUsd18);
    }

    // ========= Admin / Config =========

    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert Unauthorized();
        _;
    }

    function setSlippageBps(uint256 newBps) external onlyAdmin {
        if (newBps > BPS_DENOMINATOR) revert InvalidAmount(newBps);
        uint256 old = slippageBps;
        slippageBps = newBps;
        emit SlippageUpdated(old, newBps);
    }

    function setPerUserDailyWithdrawLimitUsd18(uint256 newLimitUsd18) external onlyAdmin {
        uint256 old = perUserDailyWithdrawLimitUsd18;
        perUserDailyWithdrawLimitUsd18 = newLimitUsd18;
        emit PerUserWithdrawLimitUpdated(old, newLimitUsd18);
    }

    function setMaxPriceAgeSeconds(uint256 newMaxSeconds) external onlyRole(RISK_ROLE) {
        maxPriceAgeSeconds = newMaxSeconds;
    }

    function setIntermediaries(address[] calldata list) external onlyAdmin {
        delete intermediaries;
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == address(0)) continue;
            intermediaries.push(list[i]);
        }
    }

    function registerToken(address token, address feed, uint8 decimals) external onlyAdmin {
        if (token == address(0)) revert InvalidAddress(token);
        if (decimals > MAX_ALLOWED_TOKEN_DECIMALS) revert InvalidAmount(decimals);
        tokenRegistry[token] = TokenInfo({ enabled: true, decimals: decimals, totalDeposited: 0, totalConvertedUsd18: 0 });
        if (feed != address(0)) priceFeeds[token] = AggregatorV3Interface(feed);
        emit TokenStatusChanged(token, true);
    }

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

    function setBankCapUsd18(uint256 newBankCapUsd18) external onlyAdmin {
        uint256 old = bankCapUsd18;
        bankCapUsd18 = newBankCapUsd18;
        emit BankCapUpdated(old, newBankCapUsd18);
    }

    /**
     * @notice Adjust internal totalDepositedUsd18 by an admin-controlled signed delta.
     * @dev Allows correcting accounting errors or applying manual adjustments. Emits event.
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
     * @notice Update price feed address for a token (optional priceFeeds map).
     */
    function updatePriceFeed(address token, address newFeed) external onlyRole(RISK_ROLE) {
        AggregatorV3Interface old = priceFeeds[token];
        priceFeeds[token] = AggregatorV3Interface(newFeed);
        emit PriceFeedUpdated(token, address(old), newFeed);
    }

    // ========= Deposits =========
    function depositETH() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert InvalidAmount(0);
        _depositCore(ETH_ADDRESS, msg.value, true);
    }

    function depositToken(address token, uint256 amount) external whenNotPaused nonReentrant {
    if (amount == 0) revert InvalidAmount(0);
    if (token == ETH_ADDRESS) revert InvalidAddress(token);

    // Validate path and auto-register decimals if needed
    if (!tokenRegistry[token].enabled) {
        _buildAndValidatePath(token, false);
        uint8 dec = 18;
        try IERC20Metadata(token).decimals() returns (uint8 d) { dec = d; } catch { dec = 18; }
        tokenRegistry[token].decimals = dec;
        tokenRegistry[token].enabled = true;
        emit TokenStatusChanged(token, true);
    }

    // measure actual received (handles fee-on-transfer tokens)
    IERC20 tokenContract = IERC20(token);
    uint256 balanceBefore = tokenContract.balanceOf(address(this));
    tokenContract.safeTransferFrom(msg.sender, address(this), amount);
    uint256 balanceAfter = tokenContract.balanceOf(address(this));
    uint256 received = balanceAfter - balanceBefore;
    if (received == 0) revert InvalidAmount(0);

    _depositCoreWithReceived(token, received, false);
}

function _depositCoreWithReceived(address token, uint256 receivedAmount, bool isETH) internal {
    uint256 usdcRawReceived;

    if (token == USDC) {
        // direct USDC deposit: measure actual received (already passed)
        usdcRawReceived = receivedAmount;
    } else {
        address[] memory path = _buildAndValidatePath(token, isETH);

        // compute expected out using the token amount in its raw units
        uint256[] memory amountsOut;
        try uniswapRouter.getAmountsOut(receivedAmount, path) returns (uint256[] memory ao) {
            amountsOut = ao;
        } catch {
            revert SwapFailed(token, USDC, receivedAmount);
        }

        uint256 expected = amountsOut[amountsOut.length - 1];
        uint256 amountOutMin = (expected * (BPS_DENOMINATOR - slippageBps)) / BPS_DENOMINATOR;

        // measure USDC balance before swap to compute actual received reliably
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(this));

        if (isETH) {
            try uniswapRouter.swapExactETHForTokens{value: receivedAmount}(amountOutMin, path, address(this), block.timestamp + 300) {
            } catch {
                revert SwapFailed(ETH_ADDRESS, USDC, receivedAmount);
            }
        } else {
            // ensure allowance for router (from this contract)
            _ensureAllowance(IERC20(token), address(uniswapRouter), receivedAmount);

            try uniswapRouter.swapExactTokensForTokens(receivedAmount, amountOutMin, path, address(this), block.timestamp + 300) {
            } catch {
                revert SwapFailed(token, USDC, receivedAmount);
            }
        }

        uint256 usdcAfter = IERC20(USDC).balanceOf(address(this));
        usdcRawReceived = usdcAfter - usdcBefore;

        if (usdcRawReceived < amountOutMin) revert SlippageExceeded(expected, usdcRawReceived);
        emit SwapExecuted(isETH ? address(0) : token, USDC, receivedAmount, usdcRawReceived);
    }

    // accounting: convert USDC raw to usd18
    uint256 usd18 = _toUsd18(USDC, usdcRawReceived);
    if (totalDepositedUsd18 + usd18 > bankCapUsd18) revert BankCapExceeded(totalDepositedUsd18 + usd18, bankCapUsd18);

    // update registry and user records (use the receivedAmount as effective token units)
    tokenRegistry[token].totalDeposited += (token == USDC) ? usdcRawReceived : receivedAmount;
    tokenRegistry[token].totalConvertedUsd18 += usd18;

    DepositInfo storage di = userDeposits[msg.sender][token];
    di.amountToken += (token == USDC) ? usdcRawReceived : receivedAmount;
    di.amountUSDC += usdcRawReceived;
    di.lastDeposit = block.timestamp;

    // balances and global accounting
    userUSDCBalance[msg.sender] += usdcRawReceived;
    totalDepositedUsd18 += usd18;

    BankAccounting storage acc = accounting;
    acc.totalDepositsUsd18 += usd18;
    acc.totalConvertedUSDC += usdcRawReceived;
    acc.totalSwapsExecuted += (token == USDC ? 0 : 1);
    acc.lastUpdateTimestamp = block.timestamp;

    emit DepositMade(msg.sender, token, (token == USDC) ? usdcRawReceived : receivedAmount, usdcRawReceived, block.timestamp);
}

    // small wrapper to keep original internal flow
    function _depositCore(address token, uint256 amount, bool isETH) internal {
        _depositCoreWithReceived(token, amount, isETH);
    }

    // ========= Path building =========
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

    // ========= Withdrawals =========
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

    // internal transfer between users (USDC balance)
    function transferInternal(address to, uint256 usdcRawAmount) external whenNotPaused nonReentrant {
        if (to == address(0)) revert InvalidAddress(to);
        if (usdcRawAmount == 0) revert InvalidAmount(0);
        uint256 balance = userUSDCBalance[msg.sender];
        if (usdcRawAmount > balance) revert InsufficientBalance(msg.sender, usdcRawAmount, balance);

        userUSDCBalance[msg.sender] = balance - usdcRawAmount;
        userUSDCBalance[to] += usdcRawAmount;

        emit TransferInternal(msg.sender, to, usdcRawAmount, block.timestamp);
    }

    // ========= Helpers =========
    function _ensureAllowance(IERC20 tokenContract, address spender, uint256 amount) internal {
        uint256 current = tokenContract.allowance(address(this), spender);
        if (current >= amount) return;

        // Try standard approve (may revert)
        try tokenContract.approve(spender, amount) {
            return;
        } catch {
            // Fallback to low-level sequence to handle non-standard tokens
            if (current != 0) {
                (bool ok0, bytes memory ret0) = address(tokenContract).call(abi.encodeWithSelector(tokenContract.approve.selector, spender, 0));
                require(ok0 && (ret0.length == 0 || abi.decode(ret0, (bool))), "approve(0) failed");
            }
            (bool ok1, bytes memory ret1) = address(tokenContract).call(abi.encodeWithSelector(tokenContract.approve.selector, spender, amount));
            require(ok1 && (ret1.length == 0 || abi.decode(ret1, (bool))), "approve(amount) failed");
        }
    }

    function _toUsd18(address token, uint256 rawAmount) internal view returns (uint256) {
        uint8 dec = tokenRegistry[token].decimals;
        if (dec == 0) {
            try IERC20Metadata(token).decimals() returns (uint8 d) { dec = d; } catch { dec = 18; }
        }
        if (dec == 18) return rawAmount;
        else if (dec < 18) return rawAmount * (10 ** (18 - dec));
        else return rawAmount / (10 ** (dec - 18));
    }

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

    function _currentDay() internal view returns (uint64 start, uint64 window) {
        uint256 day = block.timestamp / 1 days;
        start = uint64(day * 1 days);
        window = 86400;
    }

    // ========= Views / Utils =========
    function supportsToken(address token) external view returns (bool) {
        if (token == USDC) return true;
        if (tokenRegistry[token].enabled) return true;
        try this._canRoute(token) returns (bool ok) { return ok; } catch { return false; }
    }

    function _canRoute(address token) external view returns (bool) {
        if (address(uniswapFactory) == address(0)) return false;
        if (uniswapFactory.getPair(token, USDC) != address(0)) return true;
        if (WETH != address(0) && uniswapFactory.getPair(token, WETH) != address(0) && uniswapFactory.getPair(WETH, USDC) != address(0)) return true;
        return false;
    }

    function getUserUSDCBalance(address user) external view returns (uint256) {
        return userUSDCBalance[user];
    }

    // Emergency rescue for tokens (except USDC) when paused
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
        // reuse RouterUpdated event as a lightweight signal for rescue actions
        emit RouterUpdated(address(0), address(0));
    }
}