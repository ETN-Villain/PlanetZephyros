// Deploys PremiumSubscription to Electroneum testnet or mainnet and verifies it on the block
// explorer. Run with:
//   npx hardhat run scripts/deployPremiumSubscription.js --network electroneumTestnet
//   npx hardhat run scripts/deployPremiumSubscription.js --network electroneumMainnet
//
// coreToken/swapRouter are deliberately NOT constructor args here (same separation as the
// marketplace — see setupMainnetCoreBuyback_remix.ts): wire them up as a follow-up owner call
// once you know which addresses to point at (the real CORE/router on mainnet, or freshly
// deployed MockCoreToken/MockRouter on testnet via deployMockCoreAndRouter_remix.ts).
const hre = require("hardhat");

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
  console.log(
    "Next: setCoreToken() + setSwapRouter() as the OWNER account, then confirm operator/split " +
      "wiring before any real funds flow through purchasePnlPeriods."
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
