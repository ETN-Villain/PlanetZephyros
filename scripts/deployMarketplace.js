// Deploys PlanetZephyrosSubdomainNameServiceV2 to Electroneum testnet or mainnet and verifies it on the
// block explorer. Run with:
//   npx hardhat run scripts/deployMarketplace.js --network electroneumTestnet
//   npx hardhat run scripts/deployMarketplace.js --network electroneumMainnet
const hre = require("hardhat");

// Network-scoped on purpose — a deploy run with --network electroneumMainnet but a missing
// MARKETPLACE_* override must NOT silently fall back to testnet addresses.
function loadDeploymentAddresses(networkName) {
  const envVar =
    networkName === "electroneumMainnet"
      ? "NEXT_PUBLIC_ETN_MAINNET_DEPLOYMENT_ADDRESSES"
      : "NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES";
  const raw = process.env[envVar];
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(`Failed to parse ${envVar} as JSON: ${err.message}`);
  }
}

async function main() {
  const deployed = loadDeploymentAddresses(hre.network.name);

  const registrarController =
    process.env.MARKETPLACE_REGISTRAR_CONTROLLER || deployed.ETHRegistrarController;
  const nameWrapper = process.env.MARKETPLACE_NAME_WRAPPER || deployed.NameWrapper;
  const baseRegistrar =
    process.env.MARKETPLACE_BASE_REGISTRAR || deployed.BaseRegistrarImplementation;
  const defaultResolver = process.env.MARKETPLACE_DEFAULT_RESOLVER || deployed.PublicResolver;
  const projectWallet = process.env.MARKETPLACE_PROJECT_WALLET;

  const missing = Object.entries({
    registrarController,
    nameWrapper,
    baseRegistrar,
    defaultResolver,
    projectWallet,
  })
    .filter(([, v]) => !v)
    .map(([k]) => k);

  if (missing.length > 0) {
    throw new Error(
      `Missing required deployment inputs: ${missing.join(", ")}. Set NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES ` +
        `and/or the MARKETPLACE_* overrides and MARKETPLACE_PROJECT_WALLET in .env.`
    );
  }

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying PlanetZephyrosSubdomainNameServiceV2 with account:", deployer.address);
  console.log("  registrarController:", registrarController);
  console.log("  nameWrapper:        ", nameWrapper);
  console.log("  baseRegistrar:      ", baseRegistrar);
  console.log("  defaultResolver:    ", defaultResolver);
  console.log("  projectWallet:      ", projectWallet);
  console.log("  owner:              ", deployer.address);

  const constructorArgs = [
    registrarController,
    nameWrapper,
    baseRegistrar,
    defaultResolver,
    projectWallet,
    deployer.address,
  ];

  const factory = await hre.ethers.getContractFactory("PlanetZephyrosSubdomainNameServiceV2");
  const marketplace = await factory.deploy(...constructorArgs);
  await marketplace.waitForDeployment();

  const address = await marketplace.getAddress();
  console.log("PlanetZephyrosSubdomainNameServiceV2 deployed to:", address);

  const confirmations = Number(process.env.VERIFY_CONFIRMATIONS || 5);
  console.log(`Waiting for ${confirmations} confirmations before verifying...`);
  const deployTx = marketplace.deploymentTransaction();
  if (deployTx) {
    await deployTx.wait(confirmations);
  }

  try {
    await hre.run("verify:verify", {
      address,
      constructorArguments: constructorArgs,
    });
    console.log("Verified on block explorer.");
  } catch (err) {
    console.error("Verification failed:", err.message || err);
    console.error(
      "You can retry manually with:\n" +
        `  npx hardhat verify --network ${hre.network.name} ${address} ${constructorArgs
          .map((a) => `"${a}"`)
          .join(" ")}`
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
