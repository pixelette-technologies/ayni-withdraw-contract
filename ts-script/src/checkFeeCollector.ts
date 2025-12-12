import { ethers } from "ethers";
import dotenv from "dotenv";
import withdrawArtifact from "../abi/Withdraw.json" with { type: "json" };
import erc20Artifact from "../abi/ERC20Mintable.json" with { type: "json" };
import type {
  MintableErc20Contract,
  WithdrawContract
} from "../types/contracts.js";

dotenv.config();

const DOMAIN_NAME = "Withdraw";
const DOMAIN_VERSION = "1";

const WITHDRAW_TYPES = {
  Withdraw: [
    { name: "caller", type: "address" },
    { name: "token", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "recipient", type: "address" },
    { name: "fee", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" }
  ]
};

async function main() {
  const mintAmountInput = "60";
  const CONTRACT_ADDRESS = "0x7fF181437bdB2e8c56DF3C7A08309384340f48D2";
  const providerUrl = process.env.ETHEREUM_MAINNET_RPC;
  const privateKey = process.env.PRIVATE_KEY;
  const signerKey = process.env.SIGNER_PRIVATE_KEY;
  const resetIntervalSec = 600;
  const deadlineBufferSec = 120; // 2 minutes for signature expiry. Adjust this if
  const withdrawGasLimit = 1_000_000n;

  if (!providerUrl) {
    throw new Error("ETHEREUM_MAINNET_RPC env var is required");
  }

  if (!privateKey) {
    throw new Error("PRIVATE_KEY env var is required");
  }

  if (!signerKey) {
    throw new Error("SIGNER_PRIVATE_KEY env var is required");
  }

  const provider = new ethers.JsonRpcProvider(providerUrl);
  const caller = new ethers.Wallet(privateKey, provider);
  const signer = new ethers.Wallet(signerKey);
  const network = await provider.getNetwork();

  const withdraw = new ethers.Contract(
    CONTRACT_ADDRESS,
    withdrawArtifact.abi,
    caller
  ) as WithdrawContract;

  const feeCollector = await withdraw.feeCollector();
  console.log(`Fee collector for ${CONTRACT_ADDRESS}: ${feeCollector}`);

  const ayniAddress = await withdraw.ayniToken();
  console.log(`AYNI token address: ${ayniAddress}`);

  const ayniToken = new ethers.Contract(
    ayniAddress,
    erc20Artifact.abi,
    caller
  ) as MintableErc20Contract;
  const ayniDecimals = await ayniToken.decimals();
  const mintAmount = ethers.parseUnits(mintAmountInput, ayniDecimals);

  const gasUnits = 200_000n;
  const latestBlockForFee = await provider.getBlock("latest");
  if (!latestBlockForFee) {
    throw new Error("Unable to fetch latest block for gas price");
  }
  const feeGasPrice =
    latestBlockForFee.baseFeePerGas ?? (await provider.getFeeData()).gasPrice ?? 0n;
  if (feeGasPrice == 0n) {
    throw new Error("Unable to determine gas price");
  }
  const feeAmount = await withdraw.estimateFee(ayniAddress, gasUnits, feeGasPrice);

  console.log(`Minting ${mintAmountInput} AYNI to ${caller.address}...`);
  const mintTx = await ayniToken.mint(mintAmount);
  await mintTx.wait(1);
  console.log(`Minted in tx ${mintTx.hash}`);

  console.log("Approving withdraw contract...");
  const approveTx = await ayniToken.approve(CONTRACT_ADDRESS, mintAmount);
  await approveTx.wait(1);
  console.log(`Approved in tx ${approveTx.hash}`);

  const nonce = await withdraw.nonces(caller.address);
  const deadline = BigInt(Math.floor(Date.now() / 1000) + deadlineBufferSec);
  const domain = {
    name: DOMAIN_NAME,
    version: DOMAIN_VERSION,
    chainId: Number(network.chainId),
    verifyingContract: CONTRACT_ADDRESS
  };
  const message = {
    caller: caller.address,
    token: ayniAddress,
    amount: mintAmount,
    recipient: caller.address,
    fee: feeAmount,
    nonce,
    deadline
  };

  const signature = await signer.signTypedData(domain, WITHDRAW_TYPES, message);

  console.log("Calling withdraw...");
  const withdrawTx =
    await withdraw.withdraw(ayniAddress, mintAmount, caller.address, feeAmount, deadline, signature, {
      gasLimit: withdrawGasLimit
    });
  const receipt = await withdrawTx.wait(1);
  console.log(`Withdrawn in tx ${receipt?.hash ?? withdrawTx.hash}`);

  const dailyUsage = await withdraw.getCurrentDailyUsageTotal(caller.address);
  console.log(
    `Current daily usage for ${caller.address}: ${ethers.formatUnits(dailyUsage, ayniDecimals)} AYNI`
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
