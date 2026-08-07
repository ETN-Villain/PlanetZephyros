// Deploys PlanetZephyrosSubdomainNameServiceV3 via Remix's injected provider.
//
// Before running:
//  1. In Remix, compile contracts/subnames/PlanetZephyrosSubdomainNameServiceV3.sol with:
//       Solidity: 0.8.24, Enable optimization (200 runs), EVM Version: cancun, Enable viaIR
//     (Advanced Configurations in the Solidity Compiler plugin.)
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum Testnet (chain id 5201420).
//  3. Fill in PROJECT_WALLET and OWNER below.
//  4. Right click this file in the file explorer -> "Run".

import { deploy } from './ethers-lib'

// Electroneum testnet ENS-fork deployment addresses (from NEXT_PUBLIC_ETN_TESTNET_DEPLOYMENT_ADDRESSES)
const REGISTRAR_CONTROLLER: string = '0x5BFb2958062Ac12d2019Ac1E69243DDbafCCc2c5' // ETHRegistrarController
const NAME_WRAPPER: string = '0x388f495A886644883F41a5958C11382e7c0D23F5' // NameWrapper
const BASE_REGISTRAR: string = '0x7b787b31Ad58D563D7B3938b4bbfAB2c588624C5' // BaseRegistrarImplementation
const DEFAULT_RESOLVER: string = '0x1B148DF21F18cFaEC68b71FBF11692F569658b3D' // PublicResolver

// TODO: fill these in before running
const PROJECT_WALLET: string = '0x0000000000000000000000000000000000000000' // receives brokerage fees
const OWNER: string = '0x0000000000000000000000000000000000000000' // admin control (usually your deployer address)

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
    console.log(`PlanetZephyrosSubdomainNameServiceV3 deployed to: ${result.address}`)
  } catch (e) {
    console.log(e.message)
  }
})()
