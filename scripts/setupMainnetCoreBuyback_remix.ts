// Wires the real CORE token + router into a freshly-deployed mainnet marketplace, so
// buyBackAndBurn() works once burnPool has something in it. Run with the marketplace's OWNER
// account active in MetaMask — setCoreToken/setSwapRouter are both owner-only.
//
// NOTE on CORE's transfer tax: CORE's setTaxExemption() is permanently uncallable by anyone —
// its enableTrading() auto-renounces ownership as a rug-proofing measure, and owner() is already
// the zero address on-chain. This is NOT a bug and NOT fixable — buyBackAndBurn's swap is taxed
// at CORE's currentBuyBps() (checked live 2026-08-06: 1.5%, decaying toward 0% as more of CORE's
// supply burns). Factor that in (on top of normal AMM slippage) when choosing minCoreOut for an
// actual buyBackAndBurn call — the function itself needs no changes, it already computes the
// real received amount via balance-delta.
//
// Fill in MARKETPLACE_ADDRESS with the real deployed mainnet address before running.

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0x...' // TODO: fill in after deployMarketplace_mainnet_remix.ts

// Electroneum mainnet — Planet Zephyros (CORE) token + its own router, verified on-chain
// 2026-08-06: name()/symbol() match, routerAddress matches contracts/PlanetZephyrosV1.sol exactly.
const CORE_TOKEN_ADDRESS = '0x309B916b3A90cb3E071697Ea9680e9217A30066f'
const ROUTER_ADDRESS = '0x072D4706f9A383D5608BD14B09b41683cb95fFd7'

const MARKETPLACE_ABI = [
  'function setCoreToken(address _coreToken) external',
  'function setSwapRouter(address _swapRouter) external',
  'function coreToken() view returns (address)',
  'function swapRouter() view returns (address)',
]

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

;(async () => {
  try {
    if (MARKETPLACE_ADDRESS === '0x...') {
      throw new Error('Set MARKETPLACE_ADDRESS at the top of this script before running.')
    }

    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Using account (must be marketplace OWNER):', signerAddress)

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    console.log('Setting coreToken...')
    const setCoreTx = await marketplace.setCoreToken(CORE_TOKEN_ADDRESS, { gasLimit: 100000 })
    await setCoreTx.wait()

    console.log('Setting swapRouter...')
    const setRouterTx = await marketplace.setSwapRouter(ROUTER_ADDRESS, { gasLimit: 100000 })
    await setRouterTx.wait()

    const coreToken = await marketplace.coreToken()
    const swapRouter = await marketplace.swapRouter()
    console.log('coreToken() now:', coreToken, coreToken.toLowerCase() === CORE_TOKEN_ADDRESS.toLowerCase() ? 'OK' : 'MISMATCH')
    console.log('swapRouter() now:', swapRouter, swapRouter.toLowerCase() === ROUTER_ADDRESS.toLowerCase() ? 'OK' : 'MISMATCH')
  } catch (e) {
    console.log(e.message)
  }
})()
