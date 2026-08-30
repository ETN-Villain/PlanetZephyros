require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

const { subtask, vars } = require("hardhat/config");
const { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } = require("hardhat/builtin-tasks/task-names");

// contracts/v2RouterCheck.sol is abandoned scratch code (not valid Solidity) kept on disk for
// reference only; exclude it from compilation rather than deleting it.
//
// These three came in via the main_4_1_NFTcontract merge from other branches, all written for
// Remix (which resolves https:// GitHub imports natively — Hardhat's compiler doesn't, HH406).
// Excluded by filename rather than deleted; their siblings in the same directories don't use
// https imports so this is per-file, not per-directory.
const HTTPS_IMPORT_FILES = ["ETNBaseRegistrar.sol", "AetherScionsFeeReflectionV3.sol", "ZephyrosStaking.sol"];
subtask(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS).setAction(async (_, __, runSuper) => {
  const paths = await runSuper();
  return paths.filter((p) => !p.endsWith("v2RouterCheck.sol") && !HTTPS_IMPORT_FILES.some((f) => p.endsWith(f)));
});

const ELECTRONEUM_TESTNET_RPC_URL =
  process.env.NEXT_PUBLIC_ETN_TESTNET_RPC_URL || "https://rpc.ankr.com/electroneum_testnet";
const ELECTRONEUM_MAINNET_RPC_URL = process.env.NEXT_PUBLIC_ETN_MAINNET_RPC_URL || "";

// Prefer Hardhat's encrypted vars store (`npx hardhat vars set DEPLOYER_PRIVATE_KEY`, run in
// your own terminal — it prompts for the value and never writes it in plaintext or into this
// repo) over a plaintext .env entry. .env is still supported as a fallback.
const DEPLOYER_PRIVATE_KEY = vars.get("DEPLOYER_PRIVATE_KEY", process.env.DEPLOYER_PRIVATE_KEY || "");
const ELECTRONEUM_EXPLORER_API_KEY = process.env.ELECTRONEUM_EXPLORER_API_KEY || "not-required";

// Electroneum's testnet EVM does not support Shanghai/Cancun opcodes (PUSH0, MCOPY) — confirmed
// by an actual failed deployment ("invalid opcode: PUSH0"). PlanetZephyrosSubdomainNameServiceV3.sol's
// own dependency graph needs nothing newer than London (verified by isolating it from the rest
// of this repo and compiling on its own); everything else in this project keeps the default
// (some of it needs OZ v5 utils that use MCOPY), so only the marketplace contract is overridden
// down to London — this is what actually gets deployed to Electroneum.
//
// NOTE: this must use the explicit `compilers: [...]` array form, not the `{version, settings}`
// shorthand — Hardhat's config normalizer treats any object with a top-level `version` key as
// shorthand and wraps it whole into compilers[0], silently discarding a sibling `overrides` key
// in the process. Override values also need their own {version, settings} shape, not bare settings.
const SOLC_VERSION = "0.8.24";

module.exports = {
  paths: {
    tests: "./tests",
  },
  solidity: {
    compilers: [
      {
        version: SOLC_VERSION,
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
          viaIR: true,
          evmVersion: "cancun",
        },
      },
    ],
    overrides: {
      "contracts/subnames/PlanetZephyrosSubdomainNameServiceV3.sol": {
        version: SOLC_VERSION,
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true,
          evmVersion: "london",
        },
      },
      // Same Electroneum testnet EVM constraint as the marketplace above (see that comment) —
      // this contract's own logic needs nothing newer than London, so it gets the same override
      // rather than risking a PUSH0/MCOPY opcode from the default cancun target.
      "contracts/premium/PremiumSubscription.sol": {
        version: SOLC_VERSION,
        settings: {
          optimizer: { enabled: true, runs: 200 },
          viaIR: true,
          evmVersion: "london",
        },
      },
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
