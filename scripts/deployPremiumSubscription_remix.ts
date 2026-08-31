// Deploys PremiumSubscription (+ fresh testnet MockCoreToken/MockRouter for it to use) via Remix's
// injected provider — same workflow as deployMarketplace_remix.ts / deployMockCoreAndRouter_remix.ts.
//
// Before running:
//  1. In Remix, compile contracts/premium/PremiumSubscription.sol with:
//       Solidity: 0.8.24, Enable optimization (200 runs), EVM Version: london, Enable viaIR
//     (Advanced Configurations in the Solidity Compiler plugin.)
//     IMPORTANT: London, not cancun — confirmed live (see hardhat.config.js's own comment and
//     deployMockCoreAndRouter_remix.ts) that Electroneum's TESTNET EVM doesn't support Shanghai/
//     Cancun opcodes (PUSH0, MCOPY) and a cancun-targeted deploy fails outright there. (The
//     comment atop deployMarketplace_remix.ts saying "cancun" predates that discovery — don't
//     copy it; hardhat.config.js's actual override for that same contract already uses london.)
//     Also compile contracts/subnames/mocks/MockCoreToken.sol and MockRouter.sol with the exact
//     same settings, same reasoning as deployMockCoreAndRouter_remix.ts.
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum Testnet (chain id 5201420).
//  3. Fill in OWNER and OPERATOR below. splitDestination is set equal to OPERATOR (confirmed
//     design — the non-burn half of every split goes to the same wallet that executes it, no
//     separate treasury address).
//  4. Right click this file in the file explorer -> "Run".
//
// This deploys fresh mocks dedicated to PremiumSubscription's own testnet testing (not shared
// with whatever MockCoreToken/MockRouter instances may already exist from testing the marketplace)
// — cheap and unambiguous on testnet. marketplace/nameWrapper/erevosShares are deliberately left
// unwired here (see PremiumSubscription.sol: those discount paths just return false when unset,
// no revert) — they're already covered by this repo's own unit tests
// (tests/premium/PremiumSubscription.test.js) with dedicated Mock*Lite doubles; wire the real
// testnet NameWrapper (0x388f495A886644883F41a5958C11382e7c0D23F5) + a MockMarketplaceLite
// yourself afterward via Remix's "Deployed Contracts" panel if you want to exercise that path
// specifically too.

import { deploy } from './ethers-lib'

// TODO: fill these in before running
const OWNER: string = '0x0000000000000000000000000000000000000000' // your admin wallet
const OPERATOR: string = '0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099' // CORE_CLASH_BACKEND_PRIVATE_KEY's public address (confirmed)

// Arbitrary placeholder — confirmed by reading MockRouter.sol directly that it never validates
// this value (WETH() just echoes back whatever's passed at construction; the swap function only
// checks path[1] == coreToken, never path[0]). Deliberately NOT reused from OPERATOR above (the
// original deployMockCoreAndRouter_remix.ts happens to use that same literal address for its own
// unrelated reasons) — using a well-known "burn address" placeholder instead avoids any
// appearance of a real relationship between the two values.
const WETH_PLACEHOLDER = '0x000000000000000000000000000000000000dEaD'
const RATE = 1000 // CORE (wei) minted per 1 wei ETN sent through MockRouter's fake swap

const ZERO_ADDRESS: string = '0x0000000000000000000000000000000000000000'

;(async () => {
  try {
    if (OWNER === ZERO_ADDRESS) {
      throw new Error('Set OWNER at the top of this script before running.')
    }

    const premium = await deploy('PremiumSubscription', [OWNER, OPERATOR, OPERATOR])
    console.log(`PremiumSubscription deployed to: ${premium.address}`)

    const coreToken = await deploy('MockCoreToken', [])
    console.log(`MockCoreToken deployed to: ${coreToken.address}`)

    const router = await deploy('MockRouter', [coreToken.address, WETH_PLACEHOLDER, RATE])
    console.log(`MockRouter deployed to: ${router.address}`)

    console.log('Next, as the OWNER account, via Remix\'s "Deployed Contracts" panel on PremiumSubscription:')
    console.log(`  setCoreToken(${coreToken.address})`)
    console.log(`  setSwapRouter(${router.address})`)
    console.log('Then confirm OPERATOR is correct (operator() getter) before any real testnet ETN flows through purchasePnlPeriods.')
  } catch (e) {
    console.log(e.message)
  }
})()
