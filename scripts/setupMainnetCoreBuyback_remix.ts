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
import { ethers } from 'ethers'

// PlanetZephyrosSubdomainNameServiceV2, redeployed 2026-08-07 so activateDomain actually wraps a
// genuinely-unwrapped name (not just a flag flip) — block 15204649, tx
// 0x01553f1f1c0fe57afa2c229ec2bfa3199a6339592425dea92965b5f570097d6e. coreToken/swapRouter
// confirmed set correctly on this address after running this script.
// (Prior deployments, now superseded: 0x775c9BF1516811349915fC50E471875252Bb5Ef3 block 15201936;
// 0x1191C7c0558F52a7282C00Bc477aA16187C1fE64 block 15188489.)
const MARKETPLACE_ADDRESS = '0xd9BC87b41c8011c9CaEeda91167cacfFD91Cd22c'

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

;(async () => {
  try {
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
