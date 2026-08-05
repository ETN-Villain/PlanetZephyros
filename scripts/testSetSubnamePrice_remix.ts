// Test tx: sets a price for self-serve subname registration under a domain, then approves the
// marketplace on NameWrapper so registerSubname() can actually create subnames on payment. Run
// this with the domain owner's wallet active in MetaMask (whoever ran testRegisterName_remix.ts
// or testActivateDomain2_remix.ts for PARENT_LABEL below).
//
// After it finishes, switch MetaMask to a different account and run testRegisterSubname_remix.ts
// against the same PARENT_LABEL/SUB_LABEL.

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840' // TODO: update after redeploy
const NAME_WRAPPER_ADDRESS = '0x388f495A886644883F41a5958C11382e7c0D23F5'

const ETH_NODE = '0x69a3977d40595dbc343e3fa6ddbd26dbe31cc237836622384941b3c5148974cd' // namehash("etn")
const PARENT_LABEL = 'zephyrostest1' // TODO: an already-activated domain you own
const PRICE = ethers.utils.parseEther('0.1') // TODO: adjust price if desired

const MARKETPLACE_ABI = [
  'function setSubnamePrice(bytes32 parentNode, uint256 price)',
  'function domainActivated(bytes32 node) view returns (bool)',
  'event SubnamePriceSet(bytes32 indexed parentNode, uint256 price)',
]
const NAME_WRAPPER_ABI = [
  'function isApprovedForAll(address account, address operator) view returns (bool)',
  'function setApprovalForAll(address operator, bool approved)',
]

function computeNode(label: string): string {
  const labelHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(label))
  return ethers.utils.keccak256(ethers.utils.concat([ETH_NODE, labelHash]))
}

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Setting price as:', signerAddress)

    const nameWrapper = new ethers.Contract(NAME_WRAPPER_ADDRESS, NAME_WRAPPER_ABI, signer)
    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    const parentNode = computeNode(PARENT_LABEL)
    console.log('parentNode:', parentNode)

    const activated = await marketplace.domainActivated(parentNode)
    if (!activated) {
      throw new Error(`"${PARENT_LABEL}.etn" isn't activated on this marketplace deployment yet — run testActivateDomain2_remix.ts first.`)
    }

    const alreadyApproved = await nameWrapper.isApprovedForAll(signerAddress, MARKETPLACE_ADDRESS)
    if (!alreadyApproved) {
      console.log('Approving marketplace on NameWrapper...')
      const approveTx = await nameWrapper.setApprovalForAll(MARKETPLACE_ADDRESS, true)
      await approveTx.wait()
      console.log('Approved.')
    } else {
      console.log('Marketplace already approved.')
    }

    console.log(`Setting subname price for "${PARENT_LABEL}.etn" to ${ethers.utils.formatEther(PRICE)} ETN...`)
    const priceTx = await marketplace.setSubnamePrice(parentNode, PRICE)
    const receipt = await priceTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'SubnamePriceSet')
    console.log(`Price set! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('price:', ethers.utils.formatEther(event.args.price), 'ETN')
    }
    console.log('Switch MetaMask to a buyer account, then run testRegisterSubname_remix.ts.')
  } catch (e) {
    console.log(e.message)
  }
})()
