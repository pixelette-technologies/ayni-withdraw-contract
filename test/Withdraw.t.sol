// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Withdraw} from "../src/Withdraw.sol";

contract WithdrawTest is Test {
  Withdraw public withdraw;

  address ayni = 0x9d70baE2944Ffa477F37Bae227fd981E6eB31982;
  address paxg = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
  address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address feeCollector = 0xbEFd6C64E8cA1960A4028c08D8ff8e2338a5c8c8;
  address ayniUsdtPool = 0xfAf41F3761EB08374639955BDE44CBbF3dcC8384;
  address ethUsdFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address paxgUsdFeed = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
  uint32 twapWindow = 30;
  uint256 oracleMaxDelay = 25 hours;

  address alice = makeAddr("alice");
  address recipient = makeAddr("recipient");

  uint8 ayniDecimals;
  uint8 paxgDecimals;
  uint256 initialAyniBalance;
  uint256 initialPaxgBalance;

  function setUp() public {
    vm.createSelectFork("mainnet");

    withdraw =
      new Withdraw(ayni, paxg, usdt, feeCollector, ayniUsdtPool, ethUsdFeed, paxgUsdFeed, twapWindow, oracleMaxDelay);

    ayniDecimals = IERC20Metadata(ayni).decimals();
    paxgDecimals = IERC20Metadata(paxg).decimals();

    initialAyniBalance = 2_000 * (10 ** ayniDecimals);
    initialPaxgBalance = 50 * (10 ** paxgDecimals);

    deal(ayni, alice, initialAyniBalance);
    deal(paxg, alice, initialPaxgBalance);

    vm.prank(alice);
    IERC20(ayni).approve(address(withdraw), type(uint256).max);
    vm.prank(alice);
    IERC20(paxg).approve(address(withdraw), type(uint256).max);

    vm.txGasPrice(1 gwei); // Manually set gas price. Will be zero in test context otherwise
  }

  function test_deploy() public {
    assertEq(address(withdraw.ayniToken()), ayni);
    assertEq(address(withdraw.paxgToken()), paxg);
    assertEq(address(withdraw.usdtToken()), usdt);
    assertEq(address(withdraw.feeCollector()), feeCollector);
    assertEq(address(withdraw.ayniUsdtPool()), ayniUsdtPool);
    assertEq(address(withdraw.ethUsdFeed()), ethUsdFeed);
    assertEq(address(withdraw.paxgUsdFeed()), paxgUsdFeed);
    assertEq(withdraw.twapWindow(), twapWindow);
    assertEq(withdraw.oracleMaxDelay(), oracleMaxDelay);
  }

  function test_withdrawAyni() public {
    uint256 withdrawAmount = 100 * (10 ** ayniDecimals);
    uint64 dayId = uint64(block.timestamp / 1 days);

    uint256 feeCollectorBalanceBefore = IERC20(ayni).balanceOf(feeCollector);
    uint256 aliceBalanceBefore = IERC20(ayni).balanceOf(alice);

    vm.prank(alice);
    (uint256 netAmount, uint256 feeAmount) = withdraw.withdraw(Withdraw.Asset.AYNI, withdrawAmount, recipient);

    assertEq(IERC20(ayni).balanceOf(recipient), netAmount, "recipient should receive net AYNI");
    assertEq(IERC20(ayni).balanceOf(feeCollector), feeCollectorBalanceBefore + feeAmount, "fee collector mismatch");
    assertEq(IERC20(ayni).balanceOf(alice), aliceBalanceBefore - withdrawAmount, "caller should cover gross amount");
    assertEq(netAmount + feeAmount, withdrawAmount, "net + fee should equal gross");
    assertEq(withdraw.dailyUsage(alice, dayId), withdrawAmount, "daily usage not tracked");
  }

  function test_withdrawPaxg() public {
    uint256 withdrawAmount = 2 * (10 ** paxgDecimals);
    uint256 feeCollectorBalanceBefore = IERC20(paxg).balanceOf(feeCollector);
    uint256 aliceBalanceBefore = IERC20(paxg).balanceOf(alice);
    uint64 dayId = uint64(block.timestamp / 1 days);

    vm.prank(alice);
    (uint256 netAmount, uint256 feeAmount) = withdraw.withdraw(Withdraw.Asset.PAXG, withdrawAmount, recipient);

    assertEq(IERC20(paxg).balanceOf(recipient), netAmount, "recipient should receive net PAXG");
    assertEq(IERC20(paxg).balanceOf(feeCollector), feeCollectorBalanceBefore + feeAmount, "fee collector mismatch");
    assertEq(IERC20(paxg).balanceOf(alice), aliceBalanceBefore - withdrawAmount, "caller should cover gross amount");
    assertEq(withdraw.dailyUsage(alice, dayId), 0, "PAXG should not count toward AYNI limits");
  }
}
