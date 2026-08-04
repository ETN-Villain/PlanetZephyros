// Deploys PlanetZephyrosNameMarketplace to Electroneum testnet and verifies it on the block
// explorer. Run with:
//   npx hardhat run scripts/deployMarketplace.js --network electroneumTestnet
const hre = require("hardhat");

function loadDeploymentAddresses() {
  const raw = process.env.NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES;
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (err) {
    throw new Error(
      `Failed to parse NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES as JSON: ${err.message}`
    );
  }
}

async function main() {
  const deployed = loadDeploymentAddresses();

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
  console.log("Deploying PlanetZephyrosNameMarketplace with account:", deployer.address);
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

  const factory = await hre.ethers.getContractFactory("PlanetZephyrosNameMarketplace");
  const marketplace = await factory.deploy(...constructorArgs);
  await marketplace.waitForDeployment();

  const address = await marketplace.getAddress();
  console.log("PlanetZephyrosNameMarketplace deployed to:", address);

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
