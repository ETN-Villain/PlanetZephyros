// Test tx: calls activateDomain() for an already-registered-and-wrapped-but-not-activated name.
// Companion to testActivateDomain_remix.ts (the full register+wrap+activate flow) — use this one
// when the name already exists from a prior run and you just need to (re)try activation.

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840'
const REGISTRAR_CONTROLLER_ADDRESS = '0x5BFb2958062Ac12d2019Ac1E69243DDbafCCc2c5'
const NAME_WRAPPER_ADDRESS = '0x388f495A886644883F41a5958C11382e7c0D23F5'

const ETH_NODE = '0x69a3977d40595dbc343e3fa6ddbd26dbe31cc237836622384941b3c5148974cd' // namehash("etn")
const LABEL = 'zephyrosdirect1'

const CONTROLLER_ABI = [
  'function rentPrice(string label, uint256 duration) view returns (tuple(uint256 base, uint256 premium))',
]
const NAME_WRAPPER_ABI = ['function getData(uint256 id) view returns (address owner, uint32 fuses, uint64 expiry)']
const MARKETPLACE_ABI = [
  'function activateDomain(bytes32 node, string label) payable returns (uint256 fee)',
  'function brokerageBps() view returns (uint256)',
  'function domainActivated(bytes32 node) view returns (bool)',
  'event DomainActivated(bytes32 indexed node, address indexed payer, uint256 feePaid)',
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
    console.log('Using account:', signerAddress)

    const controller = new ethers.Contract(REGISTRAR_CONTROLLER_ADDRESS, CONTROLLER_ABI, signer)
    const nameWrapper = new ethers.Contract(NAME_WRAPPER_ADDRESS, NAME_WRAPPER_ABI, signer)
    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    const node = computeNode(LABEL)
    console.log('node:', node)

    const activatedBefore = await marketplace.domainActivated(node)
    console.log('domainActivated before:', activatedBefore)
    if (activatedBefore) {
      throw new Error('Already activated — nothing to do.')
    }

    // Use the wrapped name's REAL expiry (NameWrapper stores rawExpiry + a grace period, so this
    // is longer than the original registration duration — that's what caused the last attempt's
    // "Insufficient payment": the fee was estimated off the shorter raw duration instead).
    const data = await nameWrapper.getData(ethers.BigNumber.from(node))
    const currentBlock = await provider.getBlock('latest')
    const remaining = data.expiry.sub(currentBlock.timestamp)
    console.log('actual expiry:', data.expiry.toString(), '| remaining seconds:', remaining.toString())

    const price = await controller.rentPrice(LABEL, remaining)
    const basePrice = price.base.add(price.premium)
    const brokerageBps = await marketplace.brokerageBps()
    // +5% buffer over the estimate, since a few seconds pass before this actually mines (excess
    // is refunded automatically regardless).
    const feeEstimate = basePrice.mul(brokerageBps).div(10000).mul(105).div(100)
    console.log(`Calling activateDomain, sending ${ethers.utils.formatEther(feeEstimate)} ETN (excess refunded)...`)

    const activateTx = await marketplace.activateDomain(node, LABEL, { value: feeEstimate, gasLimit: 500000 })
    const receipt = await activateTx.wait()

    const event = receipt.events?.find((e: any) => e.event === 'DomainActivated')
    console.log(`Activated! tx: ${receipt.transactionHash}`)
    if (event) {
      console.log('feePaid:', ethers.utils.formatEther(event.args.feePaid), 'ETN')
    }

    const activatedAfter = await marketplace.domainActivated(node)
    console.log('domainActivated after:', activatedAfter)
  } catch (e) {
    console.log(e.message)
  }
})()
