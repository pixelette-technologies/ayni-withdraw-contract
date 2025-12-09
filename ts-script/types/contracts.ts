import { ethers } from "ethers";

export type WithdrawContract = ethers.Contract & {
  feeCollector(): Promise<string>;
  ayniToken(): Promise<string>;
  withdraw(
    token: string,
    amount: bigint,
    recipient: string,
    overrides?: ethers.ContractTransactionOptions
  ): Promise<ethers.ContractTransactionResponse>;
  getCurrentDailyUsageTotal(user: string): Promise<bigint>;
};

export type MintableErc20Contract = ethers.Contract & {
  mint(amount: bigint): Promise<ethers.ContractTransactionResponse>;
  approve(
    spender: string,
    value: bigint
  ): Promise<ethers.ContractTransactionResponse>;
  decimals(): Promise<number>;
};

