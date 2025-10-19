// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/access/AccessControl.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://raw.githubusercontent.com/smartcontractkit/chainlink/v1.11.0/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2_Improved_Normalized is Ownable, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------- Roles ----------------
    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant RISK_ROLE   = keccak256("RISK_ROLE");

    // ---------------- Constants / Immutables (USD scaled to 1e18) ----------------
    uint256 public immutable bankCapUsd18;
    uint256 public immutable withdrawLimitUsd18;

    // ---------------- Accounting (raw units) ----------------
    // token => user => raw balance (wei for ETH, token base units for ERC20)
    mapping(address => mapping(address => uint256)) private _balances;
    // token => total raw
    mapping(address => uint256) private _totalRaw;

    // ---------------- Token metadata ----------------
    mapping(address => uint8) public tokenDecimals; // token => decimals (ETH = 18)
    mapping(address => AggregatorV3Interface) public priceFeed; // token => chainlink feed token/USD

    // ---------------- Contacts ----------------
    struct Contact {
        string alias_;
        uint256 ethLimitWei;       // explicit: wei
        uint256 usdLimitUsd18;     // explicit: usd18
        bool exists;
    }
    // owner => contact => Contact
    mapping(address => mapping(address => Contact)) private _contacts;
    // owner => keccak256(alias) => contact
    mapping(address => mapping(bytes32 => address)) private _aliasIndex;

    // ---------------- Tracked total bank value ----------------
    uint256 public totalBankUsd18;

    // ---------------- Events ----------------
    event TokenRegistered(address indexed token, uint8 decimals, address feed);
    event FeedUpdated(address indexed token, address oldFeed, address newFeed);
    event Deposit(address indexed token, address indexed user, uint256 amountRaw, uint256 amountUsd18);
    event Withdrawal(address indexed token, address indexed user, uint256 amountRaw, uint256 amountUsd18);
    event InternalTransfer(address indexed token, address indexed from, address indexed to, uint256 amountRaw);
    event ContactSet(address indexed owner, address indexed contact, string alias_, uint256 ethLimitWei, uint256 usdLimitUsd18);
    event ContactRemoved(address indexed owner, address indexed contact, string alias_);

    // ---------------- Errors ----------------
    error ZeroAmount();
    error CapExceeded(uint256 attemptedUsd18, uint256 capUsd18);
    error WithdrawLimitExceeded(uint256 requestedUsd18, uint256 limitUsd18);
    error InsufficientBalance(uint256 available, uint256 required);
    error ContactNotFound();
    error AliasTaken();
    error InvalidContact();
    error BadOracle();
    error SlippageExceeded(uint256 quoteWei, uint256 sentWei, uint256 maxBps);
    error DirectEthNotAllowed();
    error BadTokenAddress();

    // ---------------- Constructor ----------------
    constructor(address owner_, uint256 _bankCapUsd18, uint256 _withdrawLimitUsd18, address ethUsdFeed) {
        require(owner_ != address(0), "owner zero");
        bankCapUsd18 = _bankCapUsd18;
        withdrawLimitUsd18 = _withdrawLimitUsd18;

        // transfer ownership to owner_ (Ownable sets deployer initially)
        _transferOwnership(owner_);

        // grant roles
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(ADMIN_ROLE, owner_);
        _grantRole(PAUSER_ROLE, owner_);
        _grantRole(RISK_ROLE, owner_);

        // register ETH defaults
        tokenDecimals[address(0)] = 18;
        priceFeed[address(0)] = AggregatorV3Interface(ethUsdFeed);
        emit TokenRegistered(address(0), 18, ethUsdFeed);
    }

    // ---------------- Admin functions ----------------

    function registerToken(address token, address feed) external onlyRole(ADMIN_ROLE) {
        if (token == address(0)) 
            revert BadTokenAddress();
        uint8 d = IERC20Metadata(token).decimals();
        tokenDecimals[token] = d;
        AggregatorV3Interface old = priceFeed[token];
        priceFeed[token] = AggregatorV3Interface(feed);
        if (address(old) == address(0)) emit TokenRegistered(token, d, feed);
        else emit FeedUpdated(token, address(old), feed);
    }

    function updateFeed(address token, address feed) external onlyRole(RISK_ROLE) {
        AggregatorV3Interface old = priceFeed[token];
        priceFeed[token] = AggregatorV3Interface(feed);
        emit FeedUpdated(token, address(old), feed);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ---------------- Price helpers (normalize to 1e18 USD) ----------------

    /// @notice returns feed price normalized to 1e18 (USD with 18 decimals)
    function priceUsd18(address token) public view returns (uint256 p18) {
        AggregatorV3Interface aggr = priceFeed[token];
        if (address(aggr) == address(0)) 
            revert BadOracle();
        (, int256 priceInt, , uint256 updatedAt, uint80 answeredInRound) = aggr.latestRoundData();
        if (priceInt <= 0 || updatedAt == 0 || answeredInRound == 0) 
            revert BadOracle();
        uint8 fd = aggr.decimals();
        uint256 u = uint256(priceInt);
        if (fd == 18) return u;
        if (fd < 18) return u * (10 ** (18 - fd));
        return u / (10 ** (fd - 18));
    }

    /// @notice Convert raw token amount to USD scaled 1e18
    function toUsd18(address token, uint256 amountRaw) public view returns (uint256 usd18) {
        if (amountRaw == 0) return 0;
        uint8 td = tokenDecimals[token];
        if (td == 0) 
            revert BadOracle();
        uint256 p18 = priceUsd18(token); // USD price scaled 1e18
        return (amountRaw * p18) / (10 ** td);
    }

    /// @notice Quote wei required to equal usd18 (round up)
    function quoteWeiForUsd18(uint256 usd18) public view returns (uint256 weiReq) {
        uint256 p18 = priceUsd18(address(0)); // ETH price USD 1e18
        if (p18 == 0) 
            revert BadOracle();
        unchecked { return (usd18 * 1e18 + p18 - 1) / p18; }
    }

    // ---------------- Deposits ----------------

    /// @notice Deposit ETH or ERC20. For ETH token==address(0) and msg.value == amountRaw
    function deposit(address token, uint256 amountRaw) external payable whenNotPaused nonReentrant {
        if (amountRaw == 0) revert ZeroAmount();

        if (token == address(0)) {
            if (msg.value != amountRaw) 
                revert ZeroAmount();
        } else {
            IERC20(token).safeTransferFrom(msg.sender, address(this), amountRaw);
        }

        uint256 amountUsd18 = toUsd18(token, amountRaw);
        _enforceBankCapOnCheck(amountUsd18);

        // Effects
        _balances[token][msg.sender] += amountRaw;
        _totalRaw[token] += amountRaw;
        totalBankUsd18 += amountUsd18;

        emit Deposit(token, msg.sender, amountRaw, amountUsd18);
    }

    /// @notice Deposit ETH by specifying USD target (with slippage tolerance in bps)
    function depositEthByUsd18(uint256 usd18, uint256 maxSlippageBps) external payable whenNotPaused nonReentrant {
        if (usd18 == 0) 
            revert ZeroAmount();
        uint256 quoteWei = quoteWeiForUsd18(usd18);
        if (!_withinSlippage(quoteWei, msg.value, maxSlippageBps)) 
            revert SlippageExceeded(quoteWei, msg.value, maxSlippageBps);

        uint256 actualUsd18 = toUsd18(address(0), msg.value);
        _enforceBankCapOnCheck(actualUsd18);

        // Effects
        _balances[address(0)][msg.sender] += msg.value;
        _totalRaw[address(0)] += msg.value;
        totalBankUsd18 += actualUsd18;

        emit Deposit(address(0), msg.sender, msg.value, actualUsd18);
    }

    // ---------------- Withdrawals ----------------

    function withdraw(address token, uint256 amountRaw) external whenNotPaused nonReentrant {
        if (amountRaw == 0) 
            revert ZeroAmount();
        uint256 bal = _balances[token][msg.sender];
        if (bal < amountRaw) 
            revert InsufficientBalance(bal, amountRaw);

        uint256 amountUsd18 = toUsd18(token, amountRaw);
        if (amountUsd18 > withdrawLimitUsd18) 
            revert WithdrawLimitExceeded(amountUsd18, withdrawLimitUsd18);

        // Effects
        _balances[token][msg.sender] = bal - amountRaw;
        _totalRaw[token] -= amountRaw;
        totalBankUsd18 = totalBankUsd18 > amountUsd18 ? totalBankUsd18 - amountUsd18 : 0;

        // Interaction
        if (token == address(0)) {
            (bool ok, ) = payable(msg.sender).call{ value: amountRaw }("");
            if (!ok) 
                revert("eth transfer failed");
        } else {
            IERC20(token).safeTransfer(msg.sender, amountRaw);
        }

        emit Withdrawal(token, msg.sender, amountRaw, amountUsd18);
    }

    // ---------------- Internal transfers & contacts ----------------

    function transferInternal(address token, address to, uint256 amountRaw) external whenNotPaused nonReentrant {
        if (amountRaw == 0) 
            revert ZeroAmount();
        if (to == address(0)) 
            revert InvalidContact();

        if (token == address(0)) {
            Contact storage c = _contacts[msg.sender][to];
            if (!c.exists) 
                revert ContactNotFound();
            if (c.ethLimitWei != 0 && amountRaw > c.ethLimitWei) 
                revert WithdrawLimitExceeded(amountRaw, c.ethLimitWei);
        }

        uint256 sb = _balances[token][msg.sender];
        if (sb < amountRaw) 
            revert InsufficientBalance(sb, amountRaw);

        _balances[token][msg.sender] = sb - amountRaw;
        _balances[token][to] += amountRaw;

        emit InternalTransfer(token, msg.sender, to, amountRaw);
    }

    function transferInternalByAlias(address token, string calldata alias_, uint256 amountRaw) external whenNotPaused nonReentrant {
        if (amountRaw == 0) 
            revert ZeroAmount();
        address to = _aliasIndex[msg.sender][keccak256(bytes(alias_))];
        Contact storage c = _contacts[msg.sender][to];
        if (!c.exists) 
            revert ContactNotFound();

        if (token == address(0) && c.ethLimitWei != 0 && amountRaw > c.ethLimitWei) 
            revert WithdrawLimitExceeded(amountRaw, c.ethLimitWei);

        uint256 sb = _balances[token][msg.sender];
        if (sb < amountRaw) 
            revert InsufficientBalance(sb, amountRaw);

        _balances[token][msg.sender] = sb - amountRaw;
        _balances[token][to] += amountRaw;

        emit InternalTransfer(token, msg.sender, to, amountRaw);
    }

    // ---------------- Contacts management ----------------

    function setContact(address contact, string calldata alias_, uint256 ethLimitWei, uint256 usdLimitUsd18) external {
        if (contact == address(0)) 
            revert InvalidContact();
        bytes32 k = keccak256(bytes(alias_));
        address current = _aliasIndex[msg.sender][k];
        if (current != address(0) && current != contact) 
            revert AliasTaken();

        Contact storage prev = _contacts[msg.sender][contact];
        if (prev.exists) {
            bytes32 oldK = keccak256(bytes(prev.alias_));
            if (oldK != k && _aliasIndex[msg.sender][oldK] == contact) 
                delete _aliasIndex[msg.sender][oldK];
        }

        _contacts[msg.sender][contact] = Contact(alias_, ethLimitWei, usdLimitUsd18, true);
        _aliasIndex[msg.sender][k] = contact;

        emit ContactSet(msg.sender, contact, alias_, ethLimitWei, usdLimitUsd18);
    }

    function removeContact(address contact) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) 
            revert ContactNotFound();
        bytes32 k = keccak256(bytes(c.alias_));
        if (_aliasIndex[msg.sender][k] == contact) 
            delete _aliasIndex[msg.sender][k];
        string memory aliasLocal = c.alias_;
        delete _contacts[msg.sender][contact];
        emit ContactRemoved(msg.sender, contact, aliasLocal);
    }

    function updateContactEthLimit(address contact, uint256 newLimitWei) external {
        Contact storage c = _contacts[msg.sender][contact];
        if (!c.exists) 
            revert ContactNotFound();
        c.ethLimitWei = newLimitWei;
        emit ContactSet(msg.sender, contact, c.alias_, c.ethLimitWei, c.usdLimitUsd18);
    }

    // ---------------- Utilities / Views ----------------

    function balanceOf(address token, address user) external view returns (uint256) {
        return _balances[token][user];
    }

    function totalOf(address token) external view returns (uint256) {
        return _totalRaw[token];
    }

    // safe slippage check: diff <= (quote * bps) / 10000
    function _withinSlippage(uint256 quote, uint256 sent, uint256 bps) private pure returns (bool) {
        if (bps > 10_000) 
            return false;
        uint256 diff = quote > sent ? quote - sent : sent - quote;
        uint256 maxAllowed = (quote * bps) / 10_000;
        return diff <= maxAllowed;
    }

    // check-only bank cap guard (reverts if would exceed)
    function _enforceBankCapOnCheck(uint256 usd18Delta) internal view {
        if (totalBankUsd18 + usd18Delta > bankCapUsd18) 
            revert CapExceeded(totalBankUsd18 + usd18Delta, bankCapUsd18);
    }

    // ---------------- Receive / Fallback ----------------
    receive() external payable { 
        revert DirectEthNotAllowed(); 
        }
    fallback() external payable { 
        revert DirectEthNotAllowed(); 
    }
}
