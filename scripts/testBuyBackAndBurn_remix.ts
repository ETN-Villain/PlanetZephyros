// Test tx: wires up the mock CORE token + router on the marketplace, then triggers
// buyBackAndBurn() to swap the accumulated burnPool for CORE and burn it.
// Run with the marketplace's OWNER account active in MetaMask — setCoreToken/setSwapRouter/
// buyBackAndBurn are all owner-only.

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0x9cDFC0b2c5eB90E5AD00d0781d3e19Ad61fDF454'
const CORE_TOKEN_ADDRESS = '0x...' // TODO: from deployMockCoreAndRouter_remix.ts output
const ROUTER_ADDRESS = '0x...' // TODO: from deployMockCoreAndRouter_remix.ts output

const MARKETPLACE_ABI = [
  'function setCoreToken(address _coreToken) external',
  'function setSwapRouter(address _swapRouter) external',
  'function buyBackAndBurn(uint256 minCoreOut, uint256 deadline) external',
  'function burnPool() view returns (uint256)',
  'function totalCoreBurned() view returns (uint256)',
  'event BuybackAndBurn(uint256 etnSpent, uint256 coreBurned)',
]

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Using account (must be contract OWNER):', signerAddress)

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    console.log('Setting coreToken...')
    const setCoreTx = await marketplace.setCoreToken(CORE_TOKEN_ADDRESS, { gasLimit: 100000 })
    await setCoreTx.wait()

    console.log('Setting swapRouter...')
    const setRouterTx = await marketplace.setSwapRouter(ROUTER_ADDRESS, { gasLimit: 100000 })
    await setRouterTx.wait()

    const burnPoolBefore = await marketplace.burnPool()
    console.log('burnPool before:', ethers.utils.formatEther(burnPoolBefore), 'ETN')

    const deadline = Math.floor(Date.now() / 1000) + 300
    console.log('Calling buyBackAndBurn...')
    const buybackTx = await marketplace.buyBackAndBurn(0, deadline, { gasLimit: 300000 })
    const receipt = await buybackTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'BuybackAndBurn')
    console.log(`Done! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('etnSpent:', ethers.utils.formatEther(event.args.etnSpent), 'ETN')
      console.log('coreBurned:', ethers.utils.formatEther(event.args.coreBurned), 'CORE')
    }

    const burnPoolAfter = await marketplace.burnPool()
    const totalBurned = await marketplace.totalCoreBurned()
    console.log('burnPool after:', ethers.utils.formatEther(burnPoolAfter), 'ETN')
    console.log('totalCoreBurned:', ethers.utils.formatEther(totalBurned), 'CORE')
  } catch (e) {
    console.log(e.message)
  }
})()
