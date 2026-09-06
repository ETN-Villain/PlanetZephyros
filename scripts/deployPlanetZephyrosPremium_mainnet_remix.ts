// Deploys PlanetZephyrosPremium to Electroneum MAINNET via Remix's injected provider — same
// workflow as deployPremiumSubscription_mainnet_remix.ts, for a genuinely separate contract (not a
// replacement/V2 of PlanetZephyrosPnLStatement — see that contract's own header comment for why
// PnL statement purchases keep running on the old one, unchanged).
//
// This contract's own new behavior (subscribe()/subscribeAnnual() attempting an immediate
// best-effort split of the payment) has never run against the real router/CORE token before —
// treat the dry run below as mandatory, not optional, same reasoning as the original
// PlanetZephyrosPnLStatement deploy.
//
// Before running:
//  1. In Remix, compile contracts/premium/PlanetZephyrosPremium.sol with:
//       Solidity: 0.8.24, Enable optimization (200 runs), EVM Version: london, Enable viaIR
//     Same EVM Version reasoning as every other mainnet deploy script in this repo: london is a
//     strict opcode subset, costs nothing extra on mainnet, and avoids re-risking a Cancun-opcode
//     surprise.
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum MAINNET (chain id 52014).
//  3. Fill in OWNER below (your real admin wallet) — this is a real, immutable mainnet
//     deployment, not testnet. OPERATOR/CORE_TOKEN/SWAP_ROUTER are pre-filled, copied from the
//     already-live PlanetZephyrosPnLStatement deployment (same operator wallet, same real
//     mainnet CORE token and router) — re-verify on Blockscout before running anyway.
//  4. Right click this file in the file explorer -> "Run".
//
// After running, the console prints the deployed address plus the exact next steps: set core
// token/router, confirm paused, then the manual dry-run sequence, then what to update in
// ETNSubdomainService (config.js's PREMIUM_ADDRESS, the ABI, backend env vars, the watcher).

import { deploy } from './ethers-lib'

// TODO: fill this in before running — your real admin wallet.
const OWNER: string = '0x0000000000000000000000000000000000000000'

// Same operator wallet as the existing PlanetZephyrosPnLStatement deployment (CORE_CLASH_BACKEND_
// PRIVATE_KEY's public address) — also receives the non-burn half of every split (splitDestination
// == OPERATOR, same confirmed design as before, no separate treasury address).
const OPERATOR: string = '0xa48Bc549a329EEd01E491C7CD950857A8ae56E73'

// Real Electroneum mainnet CORE token — same as PlanetZephyrosPnLStatement's. Re-verify on
// Blockscout before running: should be verified contract "PlanetZephyros", symbol CORE, ERC-20.
const CORE_TOKEN: string = '0x309B916b3A90cb3E071697Ea9680e9217A30066f'

// Real Electroneum mainnet Uniswap-V2-style router — same as PlanetZephyrosPnLStatement's.
// Re-verify on Blockscout before running: should be verified contract "UniswapV2Router02".
const SWAP_ROUTER: string = '0x072D4706f9A383D5608BD14B09b41683cb95fFd7'

const ZERO_ADDRESS: string = '0x0000000000000000000000000000000000000000'

;(async () => {
  try {
    if (OWNER === ZERO_ADDRESS) {
      throw new Error('Set OWNER at the top of this script before running.')
    }

    const premium = await deploy('PlanetZephyrosPremium', [OWNER, OPERATOR, OPERATOR])
    console.log(`PlanetZephyrosPremium deployed to MAINNET: ${premium.address}`)

    console.log('')
    console.log('=== REQUIRED next steps, in this order, all as the OWNER account via the "Deployed Contracts" panel ===')
    console.log('1. setPaused(true)                          -- do this FIRST, before anyone else could possibly interact')
    console.log(`2. setCoreToken(${CORE_TOKEN})`)
    console.log(`3. setSwapRouter(${SWAP_ROUTER})`)
    console.log('4. Read back owner(), operator(), splitDestination(), coreToken(), swapRouter(), paused() -- confirm every value matches what you expect before proceeding.')
    console.log('')
    console.log('=== THEN: manual small dry run (mandatory — the immediate-split path has never run live before) ===')
    console.log('5. Optionally setMembershipPricePerMonth(<small amount>) temporarily, e.g. a few ETN, to reduce real cost of the dry run.')
    console.log('6. setPaused(false)')
    console.log('7. From ANY wallet (can be OWNER itself), call subscribe(1, minCoreOut, deadline) — quote minCoreOut via the router\'s getAmountsOut against half the price, then allow ~5% slippage, matching pnlSplitExecutionScheduler.js\'s convention; deadline a few minutes out.')
    console.log('8. Confirm on Blockscout: MembershipFeeSplitExecuted was emitted (not MembershipFeeSplitDeferred), splitDestination received its half, CORE was received and burned (totalCoreBurned increased).')
    console.log('9. If step 8 shows MembershipFeeSplitDeferred instead: the membership purchase still succeeded (check isMembershipActive) — that\'s the whole point of the best-effort design — but figure out why the swap failed (bad minCoreOut, router/liquidity issue) before treating this as production-ready. The deferred fee is recoverable any time via executeMembershipSplit as OPERATOR.')
    console.log('10. If (and only if) step 8 looks correct: setMembershipPricePerMonth back to your real intended price if you lowered it in step 5, then leave paused(false) for the public.')
    console.log('')
    console.log('=== THEN: wire the new address into ETNSubdomainService (separate repo) ===')
    console.log('11. Update PREMIUM_ADDRESS in src/config.js (or the VITE_PREMIUM_ADDRESS env var) to this deployed address.')
    console.log('12. Update PremiumSubscriptionABI.json (or add a new PlanetZephyrosPremiumABI.json) to match this contract\'s actual ABI.')
    console.log('13. Point the backend\'s membership watcher at this new address/ABI so premium_memberships (and hasCoreAccess) reflect subscriptions made here — the old PlanetZephyrosPnLStatement address keeps being watched separately for PnL statement purchases, unchanged.')
    console.log('')
    console.log('=== THEN: rescue what\'s stuck in the OLD contract ===')
    console.log('14. The old PlanetZephyrosPnLStatement contract has no way to release membership fees it already collected (executeSplitForPeriod exists, but nothing has ever called it for those). As OPERATOR, call executeSplitForPeriod(amount, minCoreOut, deadline) on the OLD contract with its current membership-fee balance to recover that ETN before it\'s forgotten about.')
  } catch (e) {
    console.log(e.message)
  }
})()
