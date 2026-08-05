// Test tx: self-registers a subname under a domain that has a price set (via
// testSetSubnamePrice_remix.ts), picking SUB_LABEL and paying the domain owner's price. Run this
// with a buyer's wallet active in MetaMask (switch accounts after running
// testSetSubnamePrice_remix.ts as the domain owner).

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840' // TODO: update after redeploy
const NAME_WRAPPER_ADDRESS = '0x388f495A886644883F41a5958C11382e7c0D23F5'

const ETH_NODE = '0x69a3977d40595dbc343e3fa6ddbd26dbe31cc237836622384941b3c5148974cd' // namehash("etn")
const PARENT_LABEL = 'zephyrostest1' // TODO: must match testSetSubnamePrice_remix.ts
const SUB_LABEL = 'shop' // TODO: pick your own subname label

const MARKETPLACE_ABI = [
  'function subnamePrice(bytes32 parentNode) view returns (uint256)',
  'function registerSubname(bytes32 parentNode, string label) payable returns (bytes32 subNode)',
  'event SubnameRegistered(bytes32 indexed parentNode, string label, address indexed buyer, uint256 price, uint256 sellerAmount, uint256 burnAmount)',
]
const NAME_WRAPPER_ABI = ['function ownerOf(uint256 id) view returns (address)']

function computeNode(label: string): string {
  const labelHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(label))
  return ethers.utils.keccak256(ethers.utils.concat([ETH_NODE, labelHash]))
}

function computeSubnode(parentNode: string, label: string): string {
  const labelHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes(label))
  return ethers.utils.keccak256(ethers.utils.concat([parentNode, labelHash]))
}

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Registering subname as:', signerAddress)

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)
    const nameWrapper = new ethers.Contract(NAME_WRAPPER_ADDRESS, NAME_WRAPPER_ABI, signer)

    const parentNode = computeNode(PARENT_LABEL)
    const price = await marketplace.subnamePrice(parentNode)
    if (price.isZero()) {
      throw new Error(`"${PARENT_LABEL}.etn" isn't selling subnames — run testSetSubnamePrice_remix.ts first.`)
    }
    console.log(`Price for "${SUB_LABEL}.${PARENT_LABEL}.etn": ${ethers.utils.formatEther(price)} ETN`)

    const subNode = computeSubnode(parentNode, SUB_LABEL)
    const existingOwner = await nameWrapper.ownerOf(subNode)
    if (existingOwner !== ethers.constants.AddressZero) {
      throw new Error(`"${SUB_LABEL}.${PARENT_LABEL}.etn" is already registered to ${existingOwner} — pick a different SUB_LABEL.`)
    }

    console.log(`Registering "${SUB_LABEL}.${PARENT_LABEL}.etn"...`)
    const registerTx = await marketplace.registerSubname(parentNode, SUB_LABEL, { value: price })
    const receipt = await registerTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'SubnameRegistered')
    console.log(`Registered! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('sellerAmount:', ethers.utils.formatEther(event.args.sellerAmount), 'ETN')
      console.log('burnAmount:', ethers.utils.formatEther(event.args.burnAmount), 'ETN')
    }

    const newOwner = await nameWrapper.ownerOf(subNode)
    console.log('NameWrapper owner of subnode:', newOwner, newOwner === signerAddress ? '(matches buyer ✓)' : '(MISMATCH)')
  } catch (e) {
    console.log(e.message)
  }
})()
