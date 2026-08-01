require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { subtask, vars } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } = require("hardhat/builtin-tasks/task-names");

// contracts/v2RouterCheck.sol is abandoned scratch code (not valid Solidity) kept on disk for
// reference only; exclude it from compilation rather than deleting it.
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, __, runSuper) => {
  const paths = await runSuper();
  return paths.filter((p) => !p.endsWith("v2RouterCheck.sol"));
});

const ELECTRONEUM_TESTNET_RPC_URL =
  process.env.NEXT_PUBLIC_ETN_TESTNET_RPC_URL || "https://rpc.ankr.com/electroneum_testnet";
const ELECTRONEUM_MAINNET_RPC_URL = process.env.NEXT_PUBLIC_ETN_MAINNET_RPC_URL || "";

// Prefer Hardhat's encrypted vars store (`npx hardhat vars set DEPLOYER_PRIVATE_KEY`, run in
// your own terminal — it prompts for the value and never writes it in plaintext or into this
// repo) over a plaintext .env entry. .env is still supported as a fallback.
const DEPLOYER_PRIVATE_KEY = vars.get("DEPLOYER_PRIVATE_KEY", process.env.DEPLOYER_PRIVATE_KEY || "");
const ELECTRONEUM_EXPLORER_API_KEY = process.env.ELECTRONEUM_EXPLORER_API_KEY || "not-required";

module.exports = {
  paths: {
    tests: "./tests",
  },
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true,
      evmVersion: "cancun",
    },
  },
  networks: {
    electroneumTestnet: {
      url: ELECTRONEUM_TESTNET_RPC_URL,
      chainId: 5201420,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
    },
    electroneumMainnet: {
      url: ELECTRONEUM_MAINNET_RPC_URL,
      chainId: 52014,
      accounts: DEPLOYER_PRIVATE_KEY ? [DEPLOYER_PRIVATE_KEY] : [],
    },
  },
  etherscan: {
    apiKey: {
      electroneumTestnet: ELECTRONEUM_EXPLORER_API_KEY,
      electroneumMainnet: ELECTRONEUM_EXPLORER_API_KEY,
    },
    customChains: [
      {
        network: "electroneumTestnet",
        chainId: 5201420,
        urls: {
          // Blockscout-style API path assumed from the testnet explorer domain used by
          // ens-app-v3 (src/utils/chains/electroneumChains.ts); confirm/adjust if verification
          // requests 404.
          apiURL: "https://testnet-blockexplorer.electroneum.com/api",
          browserURL: "https://testnet-blockexplorer.electroneum.com",
        },
      },
      {
        network: "electroneumMainnet",
        chainId: 52014,
        urls: {
          apiURL: "https://blockexplorer.electroneum.com/api",
          browserURL: "https://blockexplorer.electroneum.com",
        },
      },
    ],
  },
};
