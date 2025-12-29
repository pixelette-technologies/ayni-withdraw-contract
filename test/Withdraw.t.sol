// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Withdraw} from "../src/Withdraw.sol";
import {console2} from "forge-std/console2.sol";

contract WithdrawTest is Test {
  Withdraw public withdraw;

  uint256 private constant SIGNER_PK = 0xBEEF;
  address private signer = vm.addr(SIGNER_PK);

  bytes32 private constant WITHDRAW_TYPEHASH =
    keccak256(
      "Withdraw(address caller,address token,uint256 amount,address recipient,uint256 fee,uint256 nonce,uint256 deadline)"
    );
  bytes32 private constant EIP712_DOMAIN_TYPEHASH =
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

  address ayni = 0x9d70baE2944Ffa477F37Bae227fd981E6eB31982;
  address paxg = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
  address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address feeCollector = 0xbEFd6C64E8cA1960A4028c08D8ff8e2338a5c8c8;
  address ayniUsdtPool = 0xfAf41F3761EB08374639955BDE44CBbF3dcC8384;
  address ethUsdFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address paxgUsdFeed = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
  uint32 twapWindow = 60;
  uint256 oracleMaxDelay = 25 hours;
  uint256 ayniDailyLimit = 100;

  address owner = makeAddr("owner");
  address alice = makeAddr("alice");
  address recipient = makeAddr("recipient");

  uint8 ayniDecimals;
  uint8 paxgDecimals;
  uint256 initialAyniBalance;
  uint256 initialPaxgBalance;

  function setUp() public {
    vm.createSelectFork("mainnet");

    vm.startPrank(owner);
    withdraw =
      new Withdraw(ayni, paxg, usdt, feeCollector, ayniUsdtPool, ethUsdFeed, paxgUsdFeed, twapWindow, oracleMaxDelay, ayniDailyLimit);

    withdraw.setSigner(signer, true);

    ayniDecimals = IERC20Metadata(ayni).decimals();
    paxgDecimals = IERC20Metadata(paxg).decimals();

    initialAyniBalance = 2_000 * (10 ** ayniDecimals);
    initialPaxgBalance = 50 * (10 ** paxgDecimals);

    deal(ayni, alice, initialAyniBalance);
    deal(paxg, alice, initialPaxgBalance);

    vm.stopPrank();

    vm.prank(alice);
    IERC20(ayni).approve(address(withdraw), type(uint256).max);
    vm.prank(alice);
    IERC20(paxg).approve(address(withdraw), type(uint256).max);

    vm.txGasPrice(1 gwei); // Manually set gas price. Will be zero in test context otherwise
  }

  function test_deploy() public view {
    assertEq(address(withdraw.ayniToken()), ayni);
    assertEq(address(withdraw.paxgToken()), paxg);
    assertEq(address(withdraw.usdtToken()), usdt);
    assertEq(address(withdraw.feeCollector()), feeCollector);
    assertEq(address(withdraw.ayniUsdtPool()), ayniUsdtPool);
    assertEq(address(withdraw.ethUsdFeed()), ethUsdFeed);
    assertEq(address(withdraw.paxgUsdFeed()), paxgUsdFeed);
    assertEq(withdraw.twapWindow(), twapWindow);
    assertEq(withdraw.oracleMaxDelay(), oracleMaxDelay);
    assertTrue(withdraw.isSigner(owner));
    assertTrue(withdraw.isSigner(signer));
  }

  function test_withdrawAyni() public {
    uint256 withdrawAmount = 10 * (10 ** ayniDecimals);
    uint64 dayId = withdraw.currentDayId();
    uint256 feeAmount = withdrawAmount / 10;
    uint256 deadline = block.timestamp + 1 hours;
    uint256 nonce = withdraw.nonces(alice);
    bytes memory sig = _signWithdraw(alice, ayni, withdrawAmount, recipient, feeAmount, nonce, deadline);

    uint256 feeCollectorBalanceBefore = IERC20(ayni).balanceOf(feeCollector);
    uint256 aliceBalanceBefore = IERC20(ayni).balanceOf(alice);

    vm.prank(alice);
    (uint256 netAmount, uint256 chargedFee) =
      withdraw.withdraw(ayni, withdrawAmount, recipient, feeAmount, deadline, sig);

    assertEq(IERC20(ayni).balanceOf(recipient), netAmount, "recipient should receive net AYNI");
    assertEq(IERC20(ayni).balanceOf(feeCollector), feeCollectorBalanceBefore + chargedFee, "fee collector mismatch");
    assertEq(IERC20(ayni).balanceOf(alice), aliceBalanceBefore - withdrawAmount, "caller should cover gross amount");
    assertEq(netAmount + feeAmount, withdrawAmount, "net + fee should equal gross");
    assertEq(withdraw.getDailyUsageTotal(alice, dayId), netAmount, "daily usage total mismatch");
    assertEq(withdraw.getDailyUsageCount(alice, dayId), 1, "daily usage entry count mismatch");

    (uint64 recordedTs, uint256 recordedAmount) = _getUsageEntry(alice, dayId, 0);
    assertEq(recordedAmount, netAmount, "recorded amount mismatch");
    assertGe(recordedTs, uint64(block.timestamp) - 1, "timestamp should be near block time");
  }

  function test_withdrawPaxg() public {
    uint256 withdrawAmount = 2 * (10 ** paxgDecimals);
    uint256 feeCollectorBalanceBefore = IERC20(paxg).balanceOf(feeCollector);
    uint256 aliceBalanceBefore = IERC20(paxg).balanceOf(alice);
    uint64 dayId = withdraw.currentDayId();
    uint256 feeAmount = withdrawAmount / 20;
    uint256 deadline = block.timestamp + 1 hours;
    uint256 nonce = withdraw.nonces(alice);
    bytes memory sig = _signWithdraw(alice, paxg, withdrawAmount, recipient, feeAmount, nonce, deadline);

    vm.prank(alice);
    (uint256 netAmount, uint256 chargedFee) =
      withdraw.withdraw(paxg, withdrawAmount, recipient, feeAmount, deadline, sig);

    assertEq(IERC20(paxg).balanceOf(recipient), netAmount, "recipient should receive net PAXG");
    assertEq(IERC20(paxg).balanceOf(feeCollector), feeCollectorBalanceBefore + chargedFee, "fee collector mismatch");
    assertEq(IERC20(paxg).balanceOf(alice), aliceBalanceBefore - withdrawAmount, "caller should cover gross amount");
    assertEq(withdraw.getDailyUsageTotal(alice, dayId), 0, "PAXG should not affect AYNI usage");
    assertEq(withdraw.getDailyUsageCount(alice, dayId), 0, "PAXG should not add entries");
  }

  function test_withdrawMultipleEntries() public {
    uint64 dayId = withdraw.currentDayId();
    uint256[3] memory amounts =
      [uint256(20 * (10 ** ayniDecimals)), uint256(30 * (10 ** ayniDecimals)), uint256(25 * (10 ** ayniDecimals))];

    uint256 expectedTotal;
    for (uint256 i = 0; i < amounts.length; i++) {
      uint256 feeAmount = amounts[i] / 20;
      uint256 netAmount = amounts[i] - feeAmount;
      expectedTotal += netAmount;
      uint256 deadline = block.timestamp + 1 hours;
      uint256 nonce = withdraw.nonces(alice);
      bytes memory sig = _signWithdraw(alice, ayni, amounts[i], recipient, feeAmount, nonce, deadline);
      vm.prank(alice);
      withdraw.withdraw(ayni, amounts[i], recipient, feeAmount, deadline, sig);
      vm.warp(block.timestamp + 1);
    }

    assertEq(withdraw.getDailyUsageTotal(alice, dayId), expectedTotal, "aggregate total mismatch");
    assertEq(withdraw.getDailyUsageCount(alice, dayId), amounts.length, "entry count mismatch");

    Withdraw.WithdrawalEntry[] memory entries = withdraw.getDailyUsageEntries(alice, dayId);
    assertEq(entries.length, amounts.length, "entries length mismatch");
    for (uint256 i = 0; i < entries.length; i++) {
      uint256 expectedNetAmount = amounts[i] - (amounts[i] / 20);
      assertEq(entries[i].amount, expectedNetAmount, "entry amount mismatch");
    }
  }

  function test_setAyniDailyLimit() public {
    uint256 newLimit = 1000 * (10 ** ayniDecimals);
    vm.prank(owner);
    withdraw.setAyniDailyLimit(newLimit);
    assertEq(withdraw.ayniDailyLimit(), newLimit);
  }

  function _getUsageEntry(address user, uint64 dayId, uint256 index)
    private
    view
    returns (uint64 timestamp, uint256 amount)
  {
    Withdraw.WithdrawalEntry memory entry = withdraw.getDailyUsageEntry(user, dayId, index);
    return (entry.timestamp, entry.amount);
  }

  function _signWithdraw(
    address caller,
    address token,
    uint256 amount,
    address to,
    uint256 feeAmount,
    uint256 nonce,
    uint256 deadline
  ) private view returns (bytes memory) {
    bytes32 structHash = keccak256(abi.encode(WITHDRAW_TYPEHASH, caller, token, amount, to, feeAmount, nonce, deadline));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, digest);
    return abi.encodePacked(r, s, v);
  }

  function _domainSeparator() private view returns (bytes32) {
    return keccak256(
      abi.encode(
        EIP712_DOMAIN_TYPEHASH,
        keccak256(bytes("Withdraw")),
        keccak256(bytes("1")),
        block.chainid,
        address(withdraw)
      )
    );
  }
}
