// Test tx: buys an active subname listing. Run this with the buyer's wallet active in MetaMask
// (switch accounts after running testListSubname_remix.ts as the seller).

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840'

const LISTING_ID = 1 // TODO: set to the listingId printed by testListSubname_remix.ts
const PRICE = ethers.utils.parseEther('0.1') // must match the listed price

const MARKETPLACE_ABI = [
  'function buyListing(uint256 listingId) payable',
  'event ListingSold(uint256 indexed listingId, address indexed buyer, address indexed seller, uint256 price, uint256 sellerAmount, uint256 burnAmount)',
]

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Buying as:', signerAddress)

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    console.log(`Buying listing #${LISTING_ID} for ${ethers.utils.formatEther(PRICE)} ETN...`)
    const buyTx = await marketplace.buyListing(LISTING_ID, { value: PRICE })
    const receipt = await buyTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'ListingSold')
    console.log(`Bought! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('seller:', event.args.seller)
      console.log('sellerAmount:', ethers.utils.formatEther(event.args.sellerAmount), 'ETN')
      console.log('burnAmount:', ethers.utils.formatEther(event.args.burnAmount), 'ETN')
    }
  } catch (e) {
    console.log(e.message)
  }
})()
