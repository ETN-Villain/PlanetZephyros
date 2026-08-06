// Test tx: renews an already-registered name through the marketplace's renewName(), on the
// freshly-redeployed contract (renewName didn't exist on the earlier deployment). Uses
// "zephyrostest1" — already registered on the real shared ETHRegistrarController regardless of
// which marketplace instance is live, since renewal is permissionless and doesn't depend on any
// marketplace-internal state (no domainActivated check, unlike setSubnamePricePerYear/listExistingName).
//
// Before running:
//  1. Redeploy PlanetZephyrosNameMarketplace (deployMarketplace_remix.ts) and fill in its new
//     address below.
//  2. Any funded account works — renewal isn't ownership-gated, matching the real registrar's
//     own renew().

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0x9cDFC0b2c5eB90E5AD00d0781d3e19Ad61fDF454'
const LABEL = 'zephyrostest1'
const DURATION = 30 * 24 * 60 * 60 // 30 days

const MARKETPLACE_ABI = [
  'function quoteRenewal(string label, uint256 duration) view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalPrice)',
  'function renewName(string label, uint256 duration, bytes32 referrer) payable returns (uint256 newExpiry)',
  'event NameRenewed(address indexed payer, string label, uint256 basePrice, uint256 brokerageFee, uint256 newExpiry)',
]

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Renewing as:', signerAddress)

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    const [basePrice, brokerageFee, totalPrice] = await marketplace.quoteRenewal(LABEL, DURATION)
    console.log(
      `basePrice=${ethers.utils.formatEther(basePrice)} brokerageFee=${ethers.utils.formatEther(
        brokerageFee
      )} totalPrice=${ethers.utils.formatEther(totalPrice)} ETN`
    )

    console.log(`Renewing "${LABEL}.etn" for ${DURATION} seconds...`)
    const tx = await marketplace.renewName(LABEL, DURATION, ethers.constants.HashZero, {
      value: totalPrice,
      gasLimit: 500000,
    })
    const receipt = await tx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'NameRenewed')
    console.log(`Renewed! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('newExpiry (unix seconds):', event.args.newExpiry.toString())
      console.log('newExpiry (date):', new Date(event.args.newExpiry.toNumber() * 1000).toISOString())
    }
  } catch (e) {
    console.log(e.message)
  }
})()
