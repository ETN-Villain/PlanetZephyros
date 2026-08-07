// Deploys PlanetZephyrosSubdomainNameServiceV3 to Electroneum MAINNET via Remix's injected
// provider.
//
// WHY V3: _activationFee() computed a bare percentage fee, silently skipping the
// minBrokerageFeePerYear floor that quoteRegistration/quoteRenewal both correctly apply via
// _brokerageFeeFor. Confirmed live on V2: community.etn's activation charged ~2,907 ETN instead
// of the ~25,000 ETN/year floor for its ~1 year remaining (~8.6x undercharge) — and since
// rentPrice scales linearly with remaining duration, the same ratio recurs at any duration, not
// just that one case. No admin parameter can compensate (brokerageBps is already at its
// hard-coded MAX_BROKERAGE_BPS ceiling and still falls ~8.6x short of the floor), so this needed
// new bytecode. Fix: _activationFee now calls _brokerageFeeFor(basePrice, remaining) — the exact
// same helper registerName/renewName already use correctly, instead of a separate bare calc.
//
// PRIOR DEPLOYMENTS (all superseded):
//  - 0xd9BC87b41c8011c9CaEeda91167cacfFD91Cd22c (block 15204649, tx
//    0x01553f1f1c0fe57afa2c229ec2bfa3199a6339592425dea92965b5f570097d6e) — "PlanetZephyrosSubdomainNameServiceV2",
//    fixed activateDomain to actually wrap unwrapped names (not just flip a flag), deployed
//    2026-08-07. Has the activation-fee-floor bug this V3 fixes.
//  - 0x775c9BF1516811349915fC50E471875252Bb5Ef3 (block 15201936, tx
//    0x5ca6c4067ee99def86e20b79edad75a6beff82f5467aa0a00d80c1e11c47aa22) — "PlanetZephyrosSubdomainNameService",
//    fixed activateDomain's ownership/expiry checks for unwrapped names, deployed 2026-08-07.
//  - 0x1191C7c0558F52a7282C00Bc477aA16187C1fE64 (block 15188489, tx
//    0xcdcf3bdfc327c74022690a98b955015bafb8185a63661fd3f0e891eebd78b6c9) — original
//    "PlanetZephyrosNameMarketplace" deployment. All left live/untouched on-chain (not
//    pausable-by-migration) — the frontend's MARKETPLACE_ADDRESS points at whichever is current.
//
// Before running:
//  1. In Remix, compile contracts/subnames/PlanetZephyrosSubdomainNameServiceV3.sol with:
//       Solidity: 0.8.24, Enable optimization (200 runs), EVM Version: london, Enable viaIR
//     (Advanced Configurations in the Solidity Compiler plugin.)
//     EVM Version MUST be london, not the Remix default — Electroneum testnet rejected Cancun
//     opcodes (PUSH0/MCOPY) with "invalid opcode" on a past deploy attempt, which is why
//     hardhat.config.js pins this specific contract to london for testnet. Using london here too
//     costs nothing (it's a strict opcode subset of anything newer) and avoids re-risking the
//     same failure if mainnet's EVM turns out to be equally behind.
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum Mainnet (chain id 52014).
//  3. Double check PROJECT_WALLET and OWNER below before running — this is a real, immutable
//     mainnet deployment, not testnet.
//  4. Right click this file in the file explorer -> "Run".

import { deploy } from './ethers-lib'

// Electroneum MAINNET ENS-fork deployment addresses — provided directly by the user, verified
// on-chain against https://rpc.ankr.com/electroneum (chain id 52014 confirmed) before being
// written here: all four have real deployed bytecode, and NameWrapper.registrar() returns
// exactly BASE_REGISTRAR below, confirming they're the genuine wired-together pair.
const REGISTRAR_CONTROLLER: string = '0x5cD5CEFDc5925cA6A9A38D2AA810d5aeD360b21C' // ETHRegistrarController
const NAME_WRAPPER: string = '0xd8F4B1A91469B05d9E0b15Cac4917Ee47b2A6f64' // NameWrapper
const BASE_REGISTRAR: string = '0x5207496C1248BbD2AeeDd57Bde44dd9d4E9F1b59' // BaseRegistrarImplementation
const DEFAULT_RESOLVER: string = '0xDb4A3Abb6703232e20a118a104e7f4EbB3e2738D' // PublicResolver

// Same value used for both — a plain EOA, not a multisig. Real brokerage revenue and full
// owner() admin control (fee rates, pause, CORE token/router wiring, rescueTokens) route through
// this single key on mainnet.
const PROJECT_WALLET: string = '0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099'
const OWNER: string = '0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099'

const ZERO_ADDRESS: string = '0x0000000000000000000000000000000000000000'

;(async () => {
  try {
    if (PROJECT_WALLET === ZERO_ADDRESS || OWNER === ZERO_ADDRESS) {
      throw new Error('Set PROJECT_WALLET and OWNER at the top of this script before running.')
    }

    const result = await deploy('PlanetZephyrosSubdomainNameServiceV3', [
      REGISTRAR_CONTROLLER,
      NAME_WRAPPER,
      BASE_REGISTRAR,
      DEFAULT_RESOLVER,
      PROJECT_WALLET,
      OWNER,
    ])
    console.log(`PlanetZephyrosSubdomainNameServiceV3 deployed to MAINNET: ${result.address}`)
  } catch (e) {
    console.log(e.message)
  }
})()
