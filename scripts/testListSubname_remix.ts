// Test tx: lists a new subname of zephyrostest1.etn for sale. Run this with the domain owner's
// wallet active in MetaMask (whoever ran testRegisterName_remix.ts).
//
// After it finishes, note the printed listingId, switch MetaMask to the buyer's account, and run
// testBuySubname_remix.ts with that listingId.

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840'
const NAME_WRAPPER_ADDRESS = '0x388f495A886644883F41a5958C11382e7c0D23F5'

// namehash("zephyrostest1.etn"), computed and cross-checked against the on-chain trace from the
// registerName test.
const PARENT_NODE = '0x19498c2313b9dcba8badeeea7d59ddf85dcec9af29d7b44d37a787cd0872319b'
const SUB_LABEL = 'shop' // TODO: change if you want a different subname
const PRICE = ethers.utils.parseEther('0.1') // TODO: adjust price if desired

const MARKETPLACE_ABI = [
  'function listSubname(bytes32 parentNode, string label, uint32 fuses, uint64 expiry, uint256 price) returns (uint256 listingId)',
  'event SubnameListed(uint256 indexed listingId, address indexed seller, bytes32 parentNode, string label, uint256 price)',
]
const NAME_WRAPPER_ABI = [
  'function isApprovedForAll(address account, address operator) view returns (bool)',
  'function setApprovalForAll(address operator, bool approved)',
]

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Listing as:', signerAddress)

    const nameWrapper = new ethers.Contract(NAME_WRAPPER_ADDRESS, NAME_WRAPPER_ABI, signer)
    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    const alreadyApproved = await nameWrapper.isApprovedForAll(signerAddress, MARKETPLACE_ADDRESS)
    if (!alreadyApproved) {
      console.log('Approving marketplace on NameWrapper...')
      const approveTx = await nameWrapper.setApprovalForAll(MARKETPLACE_ADDRESS, true)
      await approveTx.wait()
      console.log('Approved.')
    } else {
      console.log('Marketplace already approved.')
    }

    console.log(`Listing "${SUB_LABEL}.zephyrostest1.etn" for ${ethers.utils.formatEther(PRICE)} ETN...`)
    const listTx = await marketplace.listSubname(PARENT_NODE, SUB_LABEL, 0, 0, PRICE)
    const receipt = await listTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'SubnameListed')
    console.log(`Listed! tx: ${receipt.transactionHash}`)
    console.log('listingId:', event?.args?.listingId?.toString())
    console.log('Switch MetaMask to the buyer account, then run testBuySubname_remix.ts with this listingId.')
  } catch (e) {
    console.log(e.message)
  }
})()
