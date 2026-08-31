// Deploys PlanetZephyrosPnLStatement to Electroneum MAINNET via Remix's injected provider — same
// workflow as deployMarketplace_mainnet_remix.ts.
//
// TESTNET STATUS AS OF 2026-08-31: the testnet lifecycle scenarios (paid->generated->viewed->
// finalized->split, auto-finalize timer, refund) have NOT been run — Electroneum testnet is
// currently stalled (blocks producing but not including any transactions, confirmed via
// Blockscout). Confirmed decision: deploy to mainnet anyway, but PAUSED immediately after deploy,
// then do ONE manual small real purchase -> executeSplitForPeriod dry run yourself (as OWNER/
// OPERATOR) to prove the live swap-and-burn wiring actually works BEFORE unpausing for the public.
// This is the first-ever live use of this contract's buy-and-burn path against the real router/
// CORE token — treat the dry run as mandatory, not optional, however tempting it is to skip.
//
// Before running:
//  1. In Remix, compile contracts/premium/PremiumSubscription.sol with:
//       Solidity: 0.8.24, Enable optimization (200 runs), EVM Version: london, Enable viaIR
//     Same EVM Version reasoning as deployMarketplace_mainnet_remix.ts: london is a strict opcode
//     subset, costs nothing extra on mainnet, and avoids re-risking a Cancun-opcode surprise.
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum MAINNET (chain id 52014).
//  3. Fill in OWNER below (your real admin wallet) — this is a real, immutable mainnet
//     deployment, not testnet. OPERATOR/CORE_TOKEN/SWAP_ROUTER are pre-filled and independently
//     re-verified live on Blockscout mainnet just before this script was written (see comments).
//  4. Right click this file in the file explorer -> "Run".
//
// After running, the console prints the deployed address plus the exact next steps: set core
// token/router, confirm paused, then the manual dry-run sequence.

import { deploy } from './ethers-lib'

// TODO: fill this in before running — your real admin wallet. NOT auto-filled to the same address
// as OPERATOR below, even though that address happens to also be the Marketplace contract's
// owner() on mainnet (see deployMarketplace_mainnet_remix.ts) — confirm deliberately, don't assume.
const OWNER: string = '0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099'

// CORE_CLASH_BACKEND_PRIVATE_KEY's public address (confirmed earlier in this engagement). Also
// receives the non-burn half of every split (splitDestination == OPERATOR, confirmed design — no
// separate treasury address).
const OPERATOR: string = '0xa48Bc549a329EEd01E491C7CD950857A8ae56E73'

// Real Electroneum mainnet CORE token — re-verified live just before writing this script:
// Blockscout confirms verified contract "PlanetZephyros", symbol CORE, ERC-20, 18 decimals,
// ~822.85M supply, 71 holders.
const CORE_TOKEN: string = '0x309B916b3A90cb3E071697Ea9680e9217A30066f'

// Real Electroneum mainnet Uniswap-V2-style router — re-verified live just before writing this
// script: Blockscout confirms verified contract "UniswapV2Router02".
const SWAP_ROUTER: string = '0x072D4706f9A383D5608BD14B09b41683cb95fFd7'

const ZERO_ADDRESS: string = '0x0000000000000000000000000000000000000000'

;(async () => {
  try {
    if (OWNER === ZERO_ADDRESS) {
      throw new Error('Set OWNER at the top of this script before running.')
    }

    const premium = await deploy('PlanetZephyrosPnLStatement', [OWNER, OPERATOR, OPERATOR])
    console.log(`PlanetZephyrosPnLStatement deployed to MAINNET: ${premium.address}`)

    console.log('')
    console.log('=== REQUIRED next steps, in this order, all as the OWNER account via the "Deployed Contracts" panel ===')
    console.log('1. setPaused(true)                          -- do this FIRST, before anyone else could possibly interact')
    console.log(`2. setCoreToken(${CORE_TOKEN})`)
    console.log(`3. setSwapRouter(${SWAP_ROUTER})`)
    console.log('4. Read back owner(), operator(), splitDestination(), coreToken(), swapRouter(), paused() -- confirm every value matches what you expect before proceeding.')
    console.log('')
    console.log('=== THEN: manual small dry run (mandatory, this is the first live use of the swap/burn path) ===')
    console.log('5. Optionally setPnlPricePerPeriod(<small amount>) temporarily, e.g. a few ETN, to reduce real cost of the dry run.')
    console.log('6. setPaused(false)')
    console.log('7. From ANY wallet (can be OWNER itself), call purchasePnlPeriods with one already-ended PeriodClaim for a throwaway trackedWallet address, paying the exact price. Note the tx hash and the PnlPeriodPurchased event.')
    console.log('8. As OPERATOR, call executeSplitForPeriod(amount, minCoreOut, deadline) with that same amount. Use a generous minCoreOut buffer (e.g. quote via the router\'s getAmountsOut then allow ~5% slippage, matching autoBuyBackAndBurn.js\'s convention) and a near-future deadline.')
    console.log('9. Confirm on Blockscout: splitDestination received its half, CORE was received and burned (totalCoreBurned increased, PnlPeriodSplitExecuted emitted with a nonzero coreBurned).')
    console.log('10. If (and only if) step 9 looks correct: setPnlPricePerPeriod back to your real intended base price if you lowered it in step 5, then leave paused(false) for the public.')
  } catch (e) {
    console.log(e.message)
  }
})()
