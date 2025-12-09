// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interface/IAggregatorV3.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";
import {Oracle} from "./lib/Oracle.sol";

contract Withdraw is Ownable, ReentrancyGuard {
  using SafeERC20 for IERC20;

  enum Asset {
    AYNI,
    PAXG
  }

  IERC20 public immutable ayniToken;
  IERC20 public immutable paxgToken;
  IERC20 public immutable usdtToken;
  IUniswapV3Pool public immutable ayniUsdtPool;
  AggregatorV3Interface public immutable ethUsdFeed;
  AggregatorV3Interface public paxgUsdFeed;

  address public feeCollector;
  uint32 public twapWindow;
  uint256 public oracleMaxDelay;

  uint8 private immutable ayniDecimals;
  uint8 private immutable paxgDecimals;
  uint8 private immutable usdtDecimals;

  uint256 private constant DAILY_LIMIT = 1_000;
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

  constructor(
    address _ayni,
    address _paxg,
    address _usdt,
    address _feeCollector,
    address _ayniUsdtPool,
    address _ethUsdFeed,
    address _paxgUsdFeed,
    uint32 _twapWindow,
    uint256 _oracleMaxDelay
  ) Ownable(msg.sender) {
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

    if (IUniswapV3Pool(_ayniUsdtPool).token0() != _ayni || IUniswapV3Pool(_ayniUsdtPool).token1() != _usdt) {
      revert TokenOrderMismatch();
    }

    ayniDecimals = IERC20Metadata(_ayni).decimals();
    paxgDecimals = IERC20Metadata(_paxg).decimals();
    usdtDecimals = IERC20Metadata(_usdt).decimals();
  }

  function withdraw(Asset asset, uint256 amount, address recipient)
    external
    nonReentrant
    returns (uint256 netAmount, uint256 feeAmount)
  {
    uint256 gasStart = gasleft();
    _requireAddress(recipient);
    if (amount == 0) revert InvalidAmount();

    (IERC20 token, uint8 decimals) = _tokenData(asset);

    _enforceDailyLimit(asset, msg.sender, amount);

    feeAmount = _computeFee(asset, gasStart, decimals);
    if (feeAmount >= amount) revert FeeTooLarge(feeAmount, amount);

    netAmount = amount - feeAmount;

    token.safeTransferFrom(msg.sender, recipient, netAmount);
    if (feeAmount > 0) token.safeTransferFrom(msg.sender, feeCollector, feeAmount);

    emit Withdrawn(msg.sender, recipient, address(token), amount, netAmount, feeAmount);
  }

  function estimateFee(Asset asset, uint256 gasUnits, uint256 gasPrice) external view returns (uint256) {
    (, uint8 decimals) = _tokenData(asset);
    return _quoteFee(asset, gasUnits, decimals, gasPrice);
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

  function setFeeCollector(address newCollector) external onlyOwner {
    _requireAddress(newCollector);
    feeCollector = newCollector;
    emit FeeCollectorUpdated(newCollector);
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

  function _computeFee(Asset asset, uint256 gasStart, uint8 tokenDecimals) internal view returns (uint256) {
    uint256 gasNow = gasleft();
    uint256 gasUsed = gasStart > gasNow ? gasStart - gasNow : 0;
    return _quoteFee(asset, gasUsed, tokenDecimals, tx.gasprice);
  }

  function _tokenUsdPrice(Asset asset) internal view returns (uint256) {
    if (asset == Asset.AYNI) return _ayniUsdPrice();
    return _readFeed(paxgUsdFeed);
  }

  function _quoteFee(Asset asset, uint256 gasUnits, uint8 tokenDecimals, uint256 gasPrice)
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
    uint256 tokenUsdPrice = _tokenUsdPrice(asset);

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

  function _enforceDailyLimit(Asset asset, address user, uint256 amount) internal {
    if (asset != Asset.AYNI) return;

    uint64 dayId = _currentDayId();
    DailyUsage storage usage = _dailyUsage[user][dayId];
    uint256 newAmount = usage.total + amount;
    uint256 limit = DAILY_LIMIT * (10 ** uint256(ayniDecimals));
    if (newAmount > limit) revert DailyLimitExceeded(user, newAmount, limit);
    usage.total = newAmount;
    usage.entries.push(WithdrawalEntry({timestamp: uint64(block.timestamp), amount: amount}));
  }

  /// @dev Unix timestamps are defined relative to UTC, so dividing by 1 days advances the counter precisely at midnight
  /// UTC.
  function _currentDayId() internal view returns (uint64) {
    return uint64(block.timestamp / 1 days);
  }

  function _tokenData(Asset asset) internal view returns (IERC20 token, uint8 decimals) {
    if (asset == Asset.AYNI) return (ayniToken, ayniDecimals);
    return (paxgToken, paxgDecimals);
  }

  function _requireAddress(address account) private pure {
    if (account == address(0)) revert InvalidAddress();
  }
}