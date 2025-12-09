// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Withdraw} from "../src/Withdraw.sol";

contract DeployWithdraw is Script {

  address ayni = 0x9d70baE2944Ffa477F37Bae227fd981E6eB31982;
  address paxg = 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
  address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address feeCollector = 0xbEFd6C64E8cA1960A4028c08D8ff8e2338a5c8c8;
  address ayniUsdtPool = 0xfAf41F3761EB08374639955BDE44CBbF3dcC8384;
  address ethUsdFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
  address paxgUsdFeed = 0x9944D86CEB9160aF5C5feB251FD671923323f8C3;
  uint32 twapWindow = 30;
  uint256 oracleMaxDelay = 25 hours;

  function run() public {
    vm.createSelectFork("mainnet");
    vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

    Withdraw withdraw = new Withdraw(ayni, paxg, usdt, feeCollector, ayniUsdtPool, ethUsdFeed, paxgUsdFeed, twapWindow, oracleMaxDelay);
    
    vm.stopBroadcast();
  }
}
