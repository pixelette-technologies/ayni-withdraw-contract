// SPDX-License-Identifier: MIT
pragma solidity >=0.5.0;

import {IUniswapV3Pool} from "../interface/IUniswapV3Pool.sol";
import {TickMath} from "./TickMath.sol";
import {FullMath} from "./FullMath.sol";

library Oracle {
  error OracleWindowTooSmall();

  function consult(address pool, uint32 secondsAgo) internal view returns (int24 arithmeticMeanTick) {
    if (secondsAgo == 0) revert OracleWindowTooSmall();

    uint32[] memory secondsAgos = new uint32[](2);
    secondsAgos[0] = secondsAgo;
    secondsAgos[1] = 0;

    (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
    int56 tickDelta = tickCumulatives[1] - tickCumulatives[0];
    arithmeticMeanTick = int24(tickDelta / int56(int32(secondsAgo)));
    if (tickDelta < 0 && (tickDelta % int56(int32(secondsAgo)) != 0)) arithmeticMeanTick--;
  }

  function getQuoteAtTick(int24 tick, uint128 baseAmount, address baseToken, address quoteToken)
    internal
    pure
    returns (uint256 quoteAmount)
  {
    uint160 sqrtRatioX96 = TickMath.getSqrtRatioAtTick(tick);

    if (sqrtRatioX96 <= type(uint128).max) {
      uint256 ratioX192 = uint256(sqrtRatioX96) * sqrtRatioX96;
      quoteAmount = baseToken < quoteToken
        ? FullMath.mulDiv(ratioX192, baseAmount, 1 << 192)
        : FullMath.mulDiv(1 << 192, baseAmount, ratioX192);
    } else {
      uint256 ratioX128 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, 1 << 64);
      quoteAmount = baseToken < quoteToken
        ? FullMath.mulDiv(ratioX128, baseAmount, 1 << 128)
        : FullMath.mulDiv(1 << 128, baseAmount, ratioX128);
    }
  }
}
