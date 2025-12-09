// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "./interface/IAggregatorV3.sol";
import {IUniswapV3Pool} from "./interface/IUniswapV3Pool.sol";
import {Oracle} from "./lib/Oracle.sol";

/**
 * @title AYNI Withdraw Contract
 * @notice Handles AYNI and PAXG withdrawals with on-chain fee computation and AYNI daily limits.
 * @dev Fees are derived from gas usage, Chainlink feeds and a Uniswap TWAP for AYNI/USDT.
 */
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

  /**
   * @notice Emitted when the fee collector address is updated.
   * @param newCollector New fee collector address.
   */
  event FeeCollectorUpdated(address indexed newCollector);

  /**
   * @notice Emitted when the PAXG/USD oracle feed address is updated.
   * @param newFeed New PAXG/USD feed address.
   */
  event PaxgFeedUpdated(address indexed newFeed);

  /**
   * @notice Emitted when the maximum allowed oracle data age is updated.
   * @param newDelay New oracle max delay in seconds.
   */
  event OracleMaxDelayUpdated(uint256 newDelay);

  /**
   * @notice Emitted when the TWAP lookback window is updated.
   * @param newWindow New TWAP window in seconds.
   */
  event TwapWindowUpdated(uint32 newWindow);

  /**
   * @notice Emitted after a successful withdrawal and fee transfer.
   * @param caller Address that initiated the withdrawal.
   * @param recipient Address that received the net amount.
   * @param token Token address that was withdrawn.
   * @param grossAmount Gross amount before fees.
   * @param netAmount Net amount sent to the recipient after fees.
   * @param feeAmount Amount sent to the fee collector as protocol fee.
   */
  event Withdrawn(
    address indexed caller,
    address indexed recipient,
    address indexed token,
    uint256 grossAmount,
    uint256 netAmount,
    uint256 feeAmount
  );

  /// @notice Thrown when a zero recipient is provided.
  error InvalidRecipient();

  /// @notice Thrown when a zero withdrawal amount is provided.
  error InvalidAmount();

  /// @notice Thrown when a zero address is provided for a parameter that must be non-zero.
  error InvalidAddress();

  /// @notice Thrown when a zero fee collector address is configured.
  error FeeCollectorZero();

  /// @notice Thrown when the computed fee is greater than or equal to the gross amount.
  /// @param fee Computed fee amount.
  /// @param amount Gross amount provided for withdrawal.
  error FeeTooLarge(uint256 fee, uint256 amount);

  /// @notice Thrown when a user exceeds the per-day AYNI withdrawal limit.
  /// @param user User address whose usage exceeded the limit.
  /// @param attempted Total amount attempted for the current day.
  /// @param limit Daily AYNI withdrawal limit in token units.
  error DailyLimitExceeded(address user, uint256 attempted, uint256 limit);

  /// @notice Thrown when oracle data is considered stale.
  /// @param feed Oracle feed address that returned stale data.
  error OracleDataStale(address feed);

  /// @notice Thrown when an oracle feed returns a non-positive price.
  /// @param feed Oracle feed address that returned an invalid answer.
  error OracleAnswerNotPositive(address feed);

  /// @notice Thrown when the TWAP window is set to zero.
  error TwapWindowTooSmall();

  /// @notice Thrown when the configured AYNI/USDT pool token ordering does not match expectations.
  error TokenOrderMismatch();

  /// @notice Thrown when a zero PAXG/USD feed address is provided.
  error PaxgFeedZero();
  error DailyUsageEntryOutOfBounds();

  /**
   * @notice Deploys the withdraw contract.
   * @param _ayni AYNI token address.
   * @param _paxg PAXG token address.
   * @param _usdt USDT token address used as quote asset in the AYNI/USDT pool.
   * @param _feeCollector Address that will receive protocol fees.
   * @param _ayniUsdtPool Uniswap V3 pool address for the AYNI/USDT pair.
   * @param _ethUsdFeed Chainlink ETH/USD price feed.
   * @param _paxgUsdFeed Chainlink PAXG/USD price feed.
   * @param _twapWindow TWAP lookback window in seconds for AYNI/USDT pricing.
   * @param _oracleMaxDelay Maximum allowed age in seconds for oracle data.
   */
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

  /**
   * @notice Withdraws an asset to a recipient, charging a dynamic fee and enforcing AYNI daily limits.
   * @param asset Asset to withdraw (AYNI or PAXG).
   * @param amount Gross amount to withdraw, before fees.
   * @param recipient Address receiving the net amount.
   * @return netAmount Amount sent to the recipient after fees.
   * @return feeAmount Amount sent to the fee collector as protocol fee.
   */
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

  /**
   * @notice Updates the fee collector address.
   * @param newCollector New fee collector address.
   */
  function setFeeCollector(address newCollector) external onlyOwner {
    _requireAddress(newCollector);
    feeCollector = newCollector;
    emit FeeCollectorUpdated(newCollector);
  }

  /**
   * @notice Updates the PAXG/USD Chainlink feed.
   * @param newFeed New PAXG/USD feed address.
   */
  function setPaxgFeed(address newFeed) external onlyOwner {
    _requireAddress(newFeed);
    paxgUsdFeed = AggregatorV3Interface(newFeed);
    emit PaxgFeedUpdated(newFeed);
  }

  /**
   * @notice Updates the maximum allowed staleness for oracle data.
   * @param newDelay New oracle max delay in seconds.
   */
  function setOracleMaxDelay(uint256 newDelay) external onlyOwner {
    if (newDelay == 0) revert OracleDataStale(address(0));
    oracleMaxDelay = newDelay;
    emit OracleMaxDelayUpdated(newDelay);
  }

  /**
   * @notice Updates the TWAP lookback window used for AYNI/USDT pricing.
   * @param newWindow New TWAP window in seconds.
   */
  function setTwapWindow(uint32 newWindow) external onlyOwner {
    if (newWindow == 0) revert TwapWindowTooSmall();
    twapWindow = newWindow;
    emit TwapWindowUpdated(newWindow);
  }

  /**
   * @dev Computes the fee for a withdraw call based on actual gas used and ETH/USD and token/USD prices.
   * @param asset Asset used to pay the fee.
   * @param gasStart Gas left at the beginning of the withdraw call.
   * @param tokenDecimals Decimals for the fee token.
   * @return Fee amount in token units.
   */
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

<<<<<<< HEAD
  /**
   * @notice Estimates the withdraw fee off-chain for given gas parameters.
   * @dev Mirrors the pricing logic of `_computeFee` but takes explicit gas units and gas price.
   * @param asset Asset that will be used to pay the fee.
   * @param gasUnits Estimated gas units for the withdraw transaction.
   * @param gasPrice Gas price in wei per gas unit.
   * @return feeAmount Estimated fee in token units.
   */
  function estimateFee(Asset asset, uint256 gasUnits, uint256 gasPrice)
    external
    view
    returns (uint256 feeAmount)
  {
    if (gasUnits == 0 || gasPrice == 0) return 0;

    (IERC20 token, uint8 decimals) = _tokenData(asset);
    token;

    uint256 weiCost = gasUnits * gasPrice;
    if (weiCost == 0) return 0;

    uint256 ethUsdPrice = _readFeed(ethUsdFeed);
    uint256 usdCost = (weiCost * ethUsdPrice) / PRICE_SCALE;
    if (usdCost == 0) return 0;

    uint256 grossUsd = (usdCost * (BPS_DENOMINATOR + MARKUP_BPS)) / BPS_DENOMINATOR;
    uint256 tokenUsdPrice = _tokenUsdPrice(asset);

    return _usdToToken(grossUsd, tokenUsdPrice, decimals);
  }

  /**
   * @dev Returns the USD price for the given asset, scaled by PRICE_SCALE.
   */
  function _tokenUsdPrice(Asset asset) internal view returns (uint256) {
    if (asset == Asset.AYNI) return _ayniUsdPrice();
    return _readFeed(paxgUsdFeed);
  }

  /**
   * @dev Returns the AYNI/USD price derived from the AYNI/USDT Uniswap V3 pool and USDT decimals.
   */
  function _ayniUsdPrice() internal view returns (uint256) {
    if (twapWindow == 0) revert TwapWindowTooSmall();
    int24 tick = Oracle.consult(address(ayniUsdtPool), twapWindow);
    uint128 baseAmount = uint128(10 ** uint256(ayniDecimals));
    uint256 quote = Oracle.getQuoteAtTick(tick, baseAmount, address(ayniToken), address(usdtToken));
    return (quote * PRICE_SCALE) / (10 ** uint256(usdtDecimals));
  }

  /**
   * @dev Reads a Chainlink price feed and normalises the answer to PRICE_SCALE.
   */
  function _readFeed(AggregatorV3Interface feed) internal view returns (uint256) {
    (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
    if (answer <= 0) revert OracleAnswerNotPositive(address(feed));
    if (block.timestamp - updatedAt > oracleMaxDelay) revert OracleDataStale(address(feed));
    uint8 decimals = feed.decimals();
    return (uint256(answer) * PRICE_SCALE) / (10 ** uint256(decimals));
  }

  /**
   * @dev Converts a USD amount into token units given a token/USD price and token decimals.
   */
  function _usdToToken(uint256 usdValue, uint256 tokenUsdPrice, uint8 tokenDecimals) internal pure returns (uint256) {
    if (usdValue == 0) return 0;
    return Math.ceilDiv(usdValue * (10 ** uint256(tokenDecimals)), tokenUsdPrice);
  }

  /**
   * @dev Enforces a per-user daily AYNI withdrawal limit, expressed in token units.
   * @param asset Asset being withdrawn.
   * @param user User whose daily usage is being updated.
   * @param amount Amount being added to the user's usage for the current day.
   */
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

  /**
   * @dev Returns the current day identifier, advancing at midnight UTC.
   */
  function _currentDayId() internal view returns (uint64) {
    return uint64(block.timestamp / 1 days);
  }

  /**
   * @dev Returns the ERC20 token and decimals associated with the given asset enum.
   */
  function _tokenData(Asset asset) internal view returns (IERC20 token, uint8 decimals) {
    if (asset == Asset.AYNI) return (ayniToken, ayniDecimals);
    return (paxgToken, paxgDecimals);
  }

  function _requireAddress(address account) private pure {
    if (account == address(0)) revert InvalidAddress();
  }
}
