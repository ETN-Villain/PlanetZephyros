// Checks the marketplace's accumulated burnPool and, if there's enough in it to be worth the gas,
// swaps it for CORE and burns it via buyBackAndBurn(). Designed to run unattended on a schedule
// (Windows Task Scheduler, cron, etc.) — safe to invoke even when the pool is empty or small, it
// just logs and exits rather than reverting "Nothing to burn" or wasting gas on a trivial swap.
//
// Run with:
//   npx hardhat run scripts/autoBuyBackAndBurn.js --network electroneumMainnet
//
// Requires DEPLOYER_PRIVATE_KEY configured for the marketplace's OWNER wallet (buyBackAndBurn is
// onlyOwner) — via `npx hardhat vars set DEPLOYER_PRIVATE_KEY`, run in your own terminal on this
// machine (encrypted local storage, never written to this repo), or a .env fallback. Same key
// hardhat.config.js already wires up for deployments — see its comment for details.
const hre = require("hardhat");

const MARKETPLACE_ADDRESS = process.env.BUYBACK_MARKETPLACE_ADDRESS || "0xd9BC87b41c8011c9CaEeda91167cacfFD91Cd22c";

// Skip trivially small pools — not worth a swap+burn's gas cost for a handful of ETN. Override
// with BUYBACK_MIN_POOL_ETN if 100 isn't the right threshold for your volume.
const MIN_POOL_TO_TRIGGER = hre.ethers.parseEther(process.env.BUYBACK_MIN_POOL_ETN || "100");

// How much worse than the live router quote we're willing to accept as minCoreOut — covers
// CORE's own transfer tax (currentBuyBps(), ~1.5% and decaying as of 2026-08-06 — see
// setupMainnetCoreBuyback_remix.ts) plus ordinary price movement between quoting and the tx
// actually mining. Override with BUYBACK_SLIPPAGE_BPS if 5% turns out too tight/loose in practice.
const SLIPPAGE_BPS = BigInt(process.env.BUYBACK_SLIPPAGE_BPS || "500");

const MARKETPLACE_ABI = [
  "function burnPool() view returns (uint256)",
  "function coreToken() view returns (address)",
  "function swapRouter() view returns (address)",
  "function buyBackAndBurn(uint256 minCoreOut, uint256 deadline) external",
  "event BuybackAndBurn(uint256 etnSpent, uint256 coreBurned)",
];
const ROUTER_ABI = [
  "function WETH() view returns (address)",
  "function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[])",
];

async function main() {
  const [signer] = await hre.ethers.getSigners();
  if (!signer) {
    throw new Error(
      "No signer configured — set DEPLOYER_PRIVATE_KEY for the marketplace owner wallet " +
      "(npx hardhat vars set DEPLOYER_PRIVATE_KEY, run in your own terminal)."
    );
  }

  const marketplace = new hre.ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer);

  const pool = await marketplace.burnPool();
  console.log(`[${new Date().toISOString()}] burnPool: ${hre.ethers.formatEther(pool)} ETN`);

  if (pool < MIN_POOL_TO_TRIGGER) {
    console.log(`Below trigger threshold (${hre.ethers.formatEther(MIN_POOL_TO_TRIGGER)} ETN) — skipping, nothing to do.`);
    return;
  }

  const [coreToken, routerAddress] = await Promise.all([
    marketplace.coreToken(),
    marketplace.swapRouter(),
  ]);
  if (coreToken === hre.ethers.ZeroAddress || routerAddress === hre.ethers.ZeroAddress) {
    console.log("coreToken/swapRouter not configured on this contract — skipping.");
    return;
  }

  const router = new hre.ethers.Contract(routerAddress, ROUTER_ABI, hre.ethers.provider);
  const weth = await router.WETH();
  const amounts = await router.getAmountsOut(pool, [weth, coreToken]);
  const quotedOut = amounts[1];

  const minCoreOut = (quotedOut * (10000n - SLIPPAGE_BPS)) / 10000n;
  const deadline = Math.floor(Date.now() / 1000) + 600;

  console.log(
    `Quoted ${hre.ethers.formatEther(quotedOut)} CORE for ${hre.ethers.formatEther(pool)} ETN — ` +
    `minCoreOut (${Number(SLIPPAGE_BPS) / 100}% slippage floor): ${hre.ethers.formatEther(minCoreOut)} CORE`
  );

  const tx = await marketplace.buyBackAndBurn(minCoreOut, deadline, { gasLimit: 300000 });
  console.log(`Submitted: ${tx.hash}`);
  const receipt = await tx.wait();
  if (!receipt || receipt.status !== 1) throw new Error("buyBackAndBurn transaction failed");

  const event = receipt.logs
    .map((l) => {
      try {
        return marketplace.interface.parseLog(l);
      } catch {
        return null;
      }
    })
    .find((e) => e && e.name === "BuybackAndBurn");

  if (event) {
    console.log(
      `Done — burned ${hre.ethers.formatEther(event.args.coreBurned)} CORE ` +
      `for ${hre.ethers.formatEther(event.args.etnSpent)} ETN.`
    );
  } else {
    console.log("Done — tx succeeded but BuybackAndBurn event wasn't found in the receipt (unexpected).");
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
