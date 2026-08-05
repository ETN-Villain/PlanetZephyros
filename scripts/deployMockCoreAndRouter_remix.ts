// Deploys MockCoreToken + MockRouter to Electroneum testnet, for testing
// PlanetZephyrosNameMarketplace's buyBackAndBurn() before the real CORE token exists there.
// Run with any funded account — deploying these doesn't require being the marketplace owner.
//
// Before running: compile contracts/subnames/mocks/MockCoreToken.sol and MockRouter.sol with the
// same settings as the marketplace (optimizer on/200 runs, viaIR on, EVM Version london).

import { deploy } from './ethers-lib'

const WETH_PLACEHOLDER = '0x3Fd2e5B4AC0efF6DFDF2446abddAB3f66B425099' // arbitrary placeholder — MockRouter never validates this
const RATE = 1000 // CORE (wei) minted per 1 wei ETN sent through MockRouter's fake swap

;(async () => {
  try {
    const coreToken = await deploy('MockCoreToken', [])
    console.log(`MockCoreToken deployed to: ${coreToken.address}`)

    const router = await deploy('MockRouter', [coreToken.address, WETH_PLACEHOLDER, RATE])
    console.log(`MockRouter deployed to: ${router.address}`)

    console.log('Next: setCoreToken() + setSwapRouter() on the marketplace, as the OWNER account.')
  } catch (e) {
    console.log(e.message)
  }
})()
