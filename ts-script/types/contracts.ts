import { ethers } from "ethers";

export type WithdrawContract = ethers.Contract & {
  feeCollector(): Promise<string>;
  ayniToken(): Promise<string>;
  withdraw(
    token: string,
    amount: bigint,
    recipient: string,
    fee: bigint,
    deadline: bigint,
    signature: string,
    overrides?: ethers.ContractTransactionOptions
  ): Promise<ethers.ContractTransactionResponse>;
  getCurrentDailyUsageTotal(user: string): Promise<bigint>;
  nonces(user: string): Promise<bigint>;
  estimateFee(token: string, gasUnits: bigint, gasPrice: bigint): Promise<bigint>;
};

export type MintableErc20Contract = ethers.Contract & {
  mint(amount: bigint): Promise<ethers.ContractTransactionResponse>;
  approve(
    spender: string,
    value: bigint
  ): Promise<ethers.ContractTransactionResponse>;
  decimals(): Promise<number>;
};

