// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AggregatorV3Interface} from "./interface/IAggregatorV3.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";
import {Oracle} from "./lib/Oracle.sol";

contract Withdraw is Ownable, ReentrancyGuard, EIP712 {
  using SafeERC20 for IERC20;

  bytes32 private constant WITHDRAW_TYPEHASH =
    keccak256(
      "Withdraw(address caller,address token,uint256 amount,address recipient,uint256 fee,uint256 nonce,uint256 deadline)"
    );

  IERC20 public immutable ayniToken;
  IERC20 public immutable paxgToken;
  IERC20 public immutable usdtToken;
  IUniswapV3Pool public immutable ayniUsdtPool;
  AggregatorV3Interface public immutable ethUsdFeed;
  AggregatorV3Interface public paxgUsdFeed;
  uint256 public ayniDailyLimit;

  address public feeCollector;
  uint32 public twapWindow;
  uint256 public oracleMaxDelay;

  uint8 private immutable ayniDecimals;
  uint8 private immutable paxgDecimals;
  uint8 private immutable usdtDecimals;

  uint256 private constant BPS_DENOMINATOR = 10_000;
  uint256 private constant MARKUP_BPS = 1_500;
  uint256 private constant PRICE_SCALE = 1e18;
  uint256 private constant GAS_OVERHEAD = 50_000;

  struct WithdrawalEntry {
    uint64 timestamp;
    uint256 amount;
  }

  struct DailyUsage {
    uint256 total;
    WithdrawalEntry[] entries;
  }

  mapping(address => mapping(uint64 => DailyUsage)) private _dailyUsage;
  mapping(address => uint256) private _nonces;
  mapping(address => bool) public isSigner;

  event FeeCollectorUpdated(address indexed newCollector);
  event PaxgFeedUpdated(address indexed newFeed);
  event OracleMaxDelayUpdated(uint256 newDelay);
  event TwapWindowUpdated(uint32 newWindow);
  event Withdrawn(
    address indexed caller,
    address indexed recipient,
    address indexed token,
    uint256 grossAmount,
    uint256 netAmount,
    uint256 feeAmount
  );
  event SignerUpdated(address indexed signer, bool allowed);
  event AyniDailyLimitUpdated(uint256 newLimit);

  error InvalidRecipient();
  error InvalidAmount();
  error InvalidAddress();
  error FeeCollectorZero();
  error FeeTooLarge(uint256 fee, uint256 amount);
  error DailyLimitExceeded(address user, uint256 attempted, uint256 limit);
  error OracleDataStale(address feed);
  error OracleAnswerNotPositive(address feed);
  error TwapWindowTooSmall();
  error TokenOrderMismatch();
  error PaxgFeedZero();
  error DailyUsageEntryOutOfBounds();
  error InvalidSigner(address signer);
  error SignatureExpired(uint256 deadline);
  error UnsupportedToken(address token);

  error InvalidInput();
    error AlreadyClaimed();
    error StakeNotFound();
    error SaltAlreadyUsed();
    error InvalidClaimAddress();
    error StakeAlreadyExists();
    error InsufficientBalance();

  constructor(
    address _ayni,
    address _paxg,
    address _usdt,
    address _feeCollector,
    address _ayniUsdtPool,
    address _ethUsdFeed,
    address _paxgUsdFeed,
    uint32 _twapWindow,
    uint256 _oracleMaxDelay,
    uint256 _ayniDailyLimit
  ) Ownable(msg.sender) EIP712("Withdraw", "1") {
    _requireAddress(_ayni);
    _requireAddress(_paxg);
    _requireAddress(_usdt);
    _requireAddress(_feeCollector);
    _requireAddress(_ayniUsdtPool);
    _requireAddress(_ethUsdFeed);
    _requireAddress(_paxgUsdFeed);

    if (_twapWindow == 0) revert TwapWindowTooSmall();

    ayniToken = IERC20(_ayni);
    paxgToken = IERC20(_paxg);
    usdtToken = IERC20(_usdt);
    ayniUsdtPool = IUniswapV3Pool(_ayniUsdtPool);
    ethUsdFeed = AggregatorV3Interface(_ethUsdFeed);
    paxgUsdFeed = AggregatorV3Interface(_paxgUsdFeed);
    feeCollector = _feeCollector;
    twapWindow = _twapWindow;
    oracleMaxDelay = _oracleMaxDelay;
    ayniDailyLimit = _ayniDailyLimit;

    isSigner[msg.sender] = true;
    emit SignerUpdated(msg.sender, true);

    ayniDecimals = IERC20Metadata(_ayni).decimals();
    paxgDecimals = IERC20Metadata(_paxg).decimals();
    usdtDecimals = IERC20Metadata(_usdt).decimals();
  }

  function withdraw(
    address tokenAddress,
    uint256 amount,
    address recipient,
    uint256 feeAmount,
    uint256 deadline,
    bytes calldata signature
  ) external nonReentrant returns (uint256 netAmount, uint256 feeCharged) {
    _requireAddress(recipient);
    if (amount == 0) revert InvalidAmount();

    (IERC20 token,, bool isAyni) = _tokenData(tokenAddress);

    _verifyAndConsumeSignature(msg.sender, tokenAddress, amount, recipient, feeAmount, deadline, signature);

    if (feeAmount >= amount) revert FeeTooLarge(feeAmount, amount);

    _enforceDailyLimit(isAyni, msg.sender, amount);

    netAmount = amount - feeAmount;
    feeCharged = feeAmount;

    token.safeTransferFrom(msg.sender, recipient, netAmount);
    if (feeAmount > 0) token.safeTransferFrom(msg.sender, feeCollector, feeAmount);

    emit Withdrawn(msg.sender, recipient, address(token), amount, netAmount, feeAmount);
  }

  function estimateFee(address tokenAddress, uint256 gasUnits, uint256 gasPrice) external view returns (uint256) {
    (, uint8 decimals, bool isAyni) = _tokenData(tokenAddress);
    return _quoteFee(isAyni, gasUnits, decimals, gasPrice);
  }

  function getCurrentDailyUsageTotal(address user) external view returns (uint256) {
    return _dailyUsage[user][_currentDayId()].total;
  }

  function getDailyUsageTotal(address user, uint64 dayId) external view returns (uint256) {
    return _dailyUsage[user][dayId].total;
  }

  function getDailyUsageCount(address user, uint64 dayId) external view returns (uint256) {
    return _dailyUsage[user][dayId].entries.length;
  }

  function getDailyUsageEntry(address user, uint64 dayId, uint256 index) external view returns (WithdrawalEntry memory) {
    DailyUsage storage usage = _dailyUsage[user][dayId];
    if (index >= usage.entries.length) revert DailyUsageEntryOutOfBounds();
    return usage.entries[index];
  }

  function getDailyUsageEntries(address user, uint64 dayId) external view returns (WithdrawalEntry[] memory) {
    DailyUsage storage usage = _dailyUsage[user][dayId];
    WithdrawalEntry[] memory entries = new WithdrawalEntry[](usage.entries.length);
    for (uint256 i = 0; i < usage.entries.length; i++) {
      entries[i] = usage.entries[i];
    }
    return entries;
  }

  function nonces(address owner) external view returns (uint256) {
    return _nonces[owner];
  }

  function setFeeCollector(address newCollector) external onlyOwner {
    _requireAddress(newCollector);
    feeCollector = newCollector;
    emit FeeCollectorUpdated(newCollector);
  }

  function setSigner(address signer, bool allowed) external onlyOwner {
    _requireAddress(signer);
    isSigner[signer] = allowed;
    emit SignerUpdated(signer, allowed);
  }

  function setPaxgFeed(address newFeed) external onlyOwner {
    _requireAddress(newFeed);
    paxgUsdFeed = AggregatorV3Interface(newFeed);
    emit PaxgFeedUpdated(newFeed);
  }

  function setOracleMaxDelay(uint256 newDelay) external onlyOwner {
    if (newDelay == 0) revert OracleDataStale(address(0));
    oracleMaxDelay = newDelay;
    emit OracleMaxDelayUpdated(newDelay);
  }

  function setTwapWindow(uint32 newWindow) external onlyOwner {
    if (newWindow == 0) revert TwapWindowTooSmall();
    twapWindow = newWindow;
    emit TwapWindowUpdated(newWindow);
  }

  function setAyniDailyLimit(uint256 newLimit) external onlyOwner {
    ayniDailyLimit = newLimit;
    emit AyniDailyLimitUpdated(newLimit);
  }

  function currentDayId() external view returns (uint64) {
    return _currentDayId();
  }

  function _computeFee(bool isAyni, uint256 gasStart, uint8 tokenDecimals) internal view returns (uint256) {
    uint256 gasNow = gasleft();
    uint256 gasUsed = gasStart > gasNow ? gasStart - gasNow : 0;
    return _quoteFee(isAyni, gasUsed, tokenDecimals, tx.gasprice);
  }

  function _tokenUsdPrice(bool isAyni) internal view returns (uint256) {
    if (isAyni) return _ayniUsdPrice();
    return _readFeed(paxgUsdFeed);
  }

  function _quoteFee(bool isAyni, uint256 gasUnits, uint8 tokenDecimals, uint256 gasPrice)
    internal
    view
    returns (uint256)
  {
    if (gasPrice == 0) return 0;

    gasUnits += GAS_OVERHEAD;
    uint256 weiCost = gasUnits * gasPrice;
    if (weiCost == 0) return 0;

    uint256 ethUsdPrice = _readFeed(ethUsdFeed);
    uint256 usdCost = (weiCost * ethUsdPrice) / PRICE_SCALE;
    if (usdCost == 0) return 0;

    uint256 grossUsd = (usdCost * (BPS_DENOMINATOR + MARKUP_BPS)) / BPS_DENOMINATOR;
    uint256 tokenUsdPrice = _tokenUsdPrice(isAyni);

    return _usdToToken(grossUsd, tokenUsdPrice, tokenDecimals);
  }

  function _ayniUsdPrice() internal view returns (uint256) {
    if (twapWindow == 0) revert TwapWindowTooSmall();
    int24 tick = Oracle.consult(address(ayniUsdtPool), twapWindow);
    uint128 baseAmount = uint128(10 ** uint256(ayniDecimals));
    uint256 quote = Oracle.getQuoteAtTick(tick, baseAmount, address(ayniToken), address(usdtToken));
    return (quote * PRICE_SCALE) / (10 ** uint256(usdtDecimals));
  }

  function _readFeed(AggregatorV3Interface feed) internal view returns (uint256) {
    (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
    if (answer <= 0) revert OracleAnswerNotPositive(address(feed));
    if (block.timestamp - updatedAt > oracleMaxDelay) revert OracleDataStale(address(feed));
    uint8 decimals = feed.decimals();
    return (uint256(answer) * PRICE_SCALE) / (10 ** uint256(decimals));
  }

  function _usdToToken(uint256 usdValue, uint256 tokenUsdPrice, uint8 tokenDecimals) internal pure returns (uint256) {
    if (usdValue == 0) return 0;
    return Math.ceilDiv(usdValue * (10 ** uint256(tokenDecimals)), tokenUsdPrice);
  }

  function _enforceDailyLimit(bool isAyni, address user, uint256 amount) internal {
    if (!isAyni) return;

    uint64 dayId = _currentDayId();
    DailyUsage storage usage = _dailyUsage[user][dayId];
    uint256 newAmount = usage.total + amount;
    uint256 limit = ayniDailyLimit * (10 ** uint256(ayniDecimals));
    if (newAmount > limit) revert DailyLimitExceeded(user, newAmount, limit);
    usage.total = newAmount;
    usage.entries.push(WithdrawalEntry({timestamp: uint64(block.timestamp), amount: amount}));
  }

  /// @dev Unix timestamps are defined relative to UTC, so dividing by 1 days advances the counter precisely at midnight
  /// UTC.
  function _currentDayId() internal view returns (uint64) {
    return uint64(block.timestamp / 1 days);
  }

  function _tokenData(address tokenAddress) internal view returns (IERC20 token, uint8 decimals, bool isAyni) {
    if (tokenAddress == address(ayniToken)) {
      return (ayniToken, ayniDecimals, true);
    }
    if (tokenAddress == address(paxgToken)) {
      return (paxgToken, paxgDecimals, false);
    }
    revert UnsupportedToken(tokenAddress);
  }

  function _requireAddress(address account) private pure {
    if (account == address(0)) revert InvalidAddress();
  }

  function _hashWithdraw(
    address caller,
    address token,
    uint256 amount,
    address recipient,
    uint256 feeAmount,
    uint256 nonce,
    uint256 deadline
  ) private pure returns (bytes32) {
    return keccak256(abi.encode(WITHDRAW_TYPEHASH, caller, token, amount, recipient, feeAmount, nonce, deadline));
  }

  function _verifyAndConsumeSignature(
    address caller,
    address token,
    uint256 amount,
    address recipient,
    uint256 feeAmount,
    uint256 deadline,
    bytes calldata signature
  ) private {
    if (deadline < block.timestamp) revert SignatureExpired(deadline);
    uint256 currentNonce = _nonces[caller];
    bytes32 structHash = _hashWithdraw(caller, token, amount, recipient, feeAmount, currentNonce, deadline);
    address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
    if (!isSigner[signer]) revert InvalidSigner(signer);
    _useNonce(caller);
  }

  function _useNonce(address owner) private returns (uint256 current) {
    current = _nonces[owner];
    _nonces[owner] = current + 1;
  }
}
