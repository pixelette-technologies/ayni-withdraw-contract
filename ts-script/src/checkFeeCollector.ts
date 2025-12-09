import { ethers } from "ethers";
import dotenv from "dotenv";
import withdrawArtifact from "../abi/Withdraw.json" with { type: "json" };
import erc20Artifact from "../abi/ERC20Mintable.json" with { type: "json" };
import type {
  MintableErc20Contract,
  WithdrawContract
} from "../types/contracts.js";

dotenv.config();

async function main() {
  const mintAmountInput = "20";
  const CONTRACT_ADDRESS = process.env.WITHDRAW_ADDRESS ?? "0xf9238Abdf4c597a3Cfe1191a2263bb6459835401";
  const providerUrl = process.env.ETHEREUM_MAINNET_RPC;
  const privateKey = process.env.PRIVATE_KEY;
  const resetIntervalSec = Number(process.env.RESET_INTERVAL ?? 600);

  if (!providerUrl) {
    throw new Error("ETHEREUM_MAINNET_RPC env var is required");
  }

  if (!privateKey) {
    throw new Error("PRIVATE_KEY env var is required");
  }

  const provider = new ethers.JsonRpcProvider(providerUrl);
  const signer = new ethers.Wallet(privateKey, provider);

  const withdraw = new ethers.Contract(
    CONTRACT_ADDRESS,
    withdrawArtifact.abi,
    signer
  ) as WithdrawContract;

  const feeCollector = await withdraw.feeCollector();
  console.log(`Fee collector for ${CONTRACT_ADDRESS}: ${feeCollector}`);

  const ayniAddress = await withdraw.ayniToken();
  console.log(`AYNI token address: ${ayniAddress}`);

  const ayniToken = new ethers.Contract(
    ayniAddress,
    erc20Artifact.abi,
    signer
  ) as MintableErc20Contract;
  const ayniDecimals = await ayniToken.decimals();
  const mintAmount = ethers.parseUnits(mintAmountInput, ayniDecimals);

  console.log(`Minting ${mintAmountInput} AYNI to ${signer.address}...`);
  const mintTx = await ayniToken.mint(mintAmount);
  await mintTx.wait(1);
  console.log(`Minted in tx ${mintTx.hash}`);

  console.log("Approving withdraw contract...");
  const approveTx = await ayniToken.approve(CONTRACT_ADDRESS, mintAmount);
  await approveTx.wait(1);
  console.log(`Approved in tx ${approveTx.hash}`);

  console.log("Calling withdraw...");
  const withdrawOverrides = { gasLimit: 1000000n };
  const withdrawTx = await withdraw.withdraw(ayniAddress, mintAmount, signer.address, withdrawOverrides);
  const receipt = await withdrawTx.wait(1);
  console.log(`Withdrawn in tx ${receipt?.hash ?? withdrawTx.hash}`);

  const dailyUsage = await withdraw.getCurrentDailyUsageTotal(signer.address);
  console.log(
    `Current daily usage for ${signer.address}: ${ethers.formatUnits(dailyUsage, ayniDecimals)} AYNI`
  );

  const latestBlock = await provider.getBlock("latest");
  if (!latestBlock) {
    throw new Error("Unable to fetch latest block");
  }
  const timestamp = Number(latestBlock.timestamp);
  const elapsed = timestamp % resetIntervalSec;
  const secondsToReset = resetIntervalSec - elapsed;

  console.log(
    `Next quota reset in ~${secondsToReset} seconds (current interval ${resetIntervalSec}s)`
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
