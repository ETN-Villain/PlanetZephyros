// Deploys PremiumSubscription to Electroneum testnet or mainnet and verifies it on the block
// explorer. Run with:
//   npx hardhat run scripts/deployPremiumSubscription.js --network electroneumTestnet
//   npx hardhat run scripts/deployPremiumSubscription.js --network electroneumMainnet
//
// coreToken/swapRouter/marketplace/nameWrapper/erevosShares are deliberately NOT constructor args
// here (same separation as the marketplace itself — see setupMainnetCoreBuyback_remix.ts): wired
// up as follow-up owner calls once you know which addresses to point at (the real ones on
// mainnet, or freshly deployed mocks on testnet — MockCoreToken/MockRouter via
// deployMockCoreAndRouter_remix.ts, MockErevosShares/MockMarketplaceLite/MockNameWrapperLite
// deployed ad hoc for testnet lifecycle testing since none of those three have a real testnet
// deployment to point at).
const hre = require("hardhat");

// Network-scoped on purpose, same reasoning as deployMarketplace.js's loadDeploymentAddresses —
// these are real, live mainnet addresses and must never silently apply to a testnet deploy.
const MAINNET_DEFAULTS = {
  marketplace: "0x392fd031910e5D58650160f41a501ccc29B1eD13", // PlanetZephyrosSubdomainNameServiceV3
  nameWrapper: "0xd8F4B1A91469B05d9E0b15Cac4917Ee47b2A6f64",
  // Confirmed live via Blockscout: verified ERC-721 "Erevos Shares" (EREVOS), 9/9 minted.
  erevosShares: "0x120E438b5A79E447F78C7857c8E55C3674349f05",
};

async function main() {
  const operator = process.env.PREMIUM_OPERATOR_ADDRESS;
  if (!operator) {
    throw new Error(
      "PREMIUM_OPERATOR_ADDRESS not set — this must be the dashboard backend's execution wallet " +
        "(CORE_CLASH_BACKEND_PRIVATE_KEY's public address in ETNSubdomainService), not the deployer key."
    );
  }

  // Confirmed design: the non-burn half of every split goes to the same wallet that executes it —
  // no separate treasury address. Override with PREMIUM_SPLIT_DESTINATION only if that changes.
  const splitDestination = process.env.PREMIUM_SPLIT_DESTINATION || operator;

  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying PremiumSubscription with account:", deployer.address);
  console.log("  owner:            ", deployer.address);
  console.log("  operator:         ", operator);
  console.log("  splitDestination: ", splitDestination);

  const constructorArgs = [deployer.address, operator, splitDestination];

  const factory = await hre.ethers.getContractFactory("PremiumSubscription");
  const premium = await factory.deploy(...constructorArgs);
  await premium.waitForDeployment();

  const address = await premium.getAddress();
  console.log("PremiumSubscription deployed to:", address);

  // Mainnet: wire the real addresses automatically (defaults above), overridable via env.
  // Testnet: only wire what's explicitly provided — there's no real deployment of any of these
  // three to default to, and silently leaving them unset is the correct/expected testnet state
  // (isEligibleForFreeAccess/isActivatedDomainOwner simply return false, never revert — see the
  // contract's own zero-address checks).
  const isMainnet = hre.network.name === "electroneumMainnet";
  const marketplace = process.env.PREMIUM_MARKETPLACE_ADDRESS || (isMainnet ? MAINNET_DEFAULTS.marketplace : null);
  const nameWrapper = process.env.PREMIUM_NAME_WRAPPER_ADDRESS || (isMainnet ? MAINNET_DEFAULTS.nameWrapper : null);
  const erevosShares = process.env.PREMIUM_EREVOS_SHARES_ADDRESS || (isMainnet ? MAINNET_DEFAULTS.erevosShares : null);

  if (marketplace) {
    console.log("Setting marketplace:", marketplace);
    await (await premium.setMarketplace(marketplace)).wait();
  }
  if (nameWrapper) {
    console.log("Setting nameWrapper:", nameWrapper);
    await (await premium.setNameWrapper(nameWrapper)).wait();
  }
  if (erevosShares) {
    console.log("Setting erevosShares:", erevosShares);
    await (await premium.setErevosShares(erevosShares)).wait();
  }

  console.log(
    "Next: setCoreToken() + setSwapRouter() as the OWNER account (mocks on testnet, the real " +
      "CORE/router on mainnet), then confirm operator/split wiring before any real funds flow " +
      "through purchasePnlPeriods."
  );

  const confirmations = Number(process.env.VERIFY_CONFIRMATIONS || 5);
  console.log(`Waiting for ${confirmations} confirmations before verifying...`);
  const deployTx = premium.deploymentTransaction();
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
