// Test tx: registers a name DIRECTLY with ETHRegistrarController (bypassing the marketplace's
// brokerage entirely), then calls activateDomain() on the marketplace to retroactively unlock it
// for listSubname/listExistingName. Run with any funded MetaMask account on Electroneum Testnet.
//
// If a name is already registered+wrapped and you just need to (re)try the activateDomain step,
// use testActivateDomain2_remix.ts instead — it skips straight to that and correctly bases the
// fee estimate on NameWrapper's actual stored expiry (see note below).

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840'
const REGISTRAR_CONTROLLER_ADDRESS = '0x5BFb2958062Ac12d2019Ac1E69243DDbafCCc2c5'
const NAME_WRAPPER_ADDRESS = '0x388f495A886644883F41a5958C11382e7c0D23F5'
const BASE_REGISTRAR_ADDRESS = '0x7b787b31Ad58D563D7B3938b4bbfAB2c588624C5'
const PUBLIC_RESOLVER_ADDRESS = '0x1B148DF21F18cFaEC68b71FBF11692F569658b3D'

// namehash("etn") — confirmed on-chain earlier (ENSRegistry.owner(this) == BaseRegistrar).
const ETH_NODE = '0x69a3977d40595dbc343e3fa6ddbd26dbe31cc237836622384941b3c5148974cd'

const LABEL = 'zephyrosdirect1' // TODO: change if this is already taken
const DURATION = 30 * 24 * 60 * 60 // 30 days

const REGISTRATION_TUPLE =
  'tuple(string label, address owner, uint256 duration, bytes32 secret, address resolver, bytes[] data, uint8 reverseRecord, bytes32 referrer)'

const CONTROLLER_ABI = [
  'function commit(bytes32 commitment) external',
  'function minCommitmentAge() view returns (uint256)',
  'function available(string label) returns (bool)',
  `function rentPrice(string label, uint256 duration) view returns (tuple(uint256 base, uint256 premium))`,
  `function makeCommitment(${REGISTRATION_TUPLE} registration) pure returns (bytes32)`,
  `function register(${REGISTRATION_TUPLE} registration) payable`,
]
const NAME_WRAPPER_ABI = [
  'function wrapETH2LD(string label, address wrappedOwner, uint16 ownerControlledFuses, address resolver) returns (uint64 expiry)',
  'function getData(uint256 id) view returns (address owner, uint32 fuses, uint64 expiry)',
]
const BASE_REGISTRAR_ABI = ['function approve(address to, uint256 tokenId)']
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

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

;(async () => {
  try {
    const provider = new ethers.providers.Web3Provider(web3Provider)
    const signer = provider.getSigner()
    const signerAddress = await signer.getAddress()
    console.log('Using account:', signerAddress)

    const controller = new ethers.Contract(REGISTRAR_CONTROLLER_ADDRESS, CONTROLLER_ABI, signer)
    const nameWrapper = new ethers.Contract(NAME_WRAPPER_ADDRESS, NAME_WRAPPER_ABI, signer)
    const baseRegistrar = new ethers.Contract(BASE_REGISTRAR_ADDRESS, BASE_REGISTRAR_ABI, signer)
    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)

    const node = computeNode(LABEL)
    console.log('node:', node)

    // --- Step 1: register DIRECTLY, bypassing the marketplace entirely ---
    const isAvailable = await controller.callStatic.available(LABEL)
    if (!isAvailable) {
      throw new Error(`"${LABEL}" is not available — change LABEL and try again.`)
    }

    const alreadyActivated = await marketplace.domainActivated(node)
    console.log('domainActivated before:', alreadyActivated)

    const secret = ethers.utils.hexlify(ethers.utils.randomBytes(32))
    const registration = {
      label: LABEL,
      owner: signerAddress,
      duration: DURATION,
      secret,
      resolver: ethers.constants.AddressZero,
      data: [],
      reverseRecord: 0,
      referrer: ethers.constants.HashZero,
    }

    const commitment = await controller.makeCommitment(registration)
    console.log('Submitting commit()...')
    const commitTx = await controller.commit(commitment, { gasLimit: 150000 })
    await commitTx.wait()

    const minCommitmentAge = await controller.minCommitmentAge()
    const waitSeconds = minCommitmentAge.toNumber() + 10
    console.log(`Committed. Waiting ${waitSeconds}s...`)
    await sleep(waitSeconds * 1000)

    const regPrice = await controller.rentPrice(LABEL, DURATION)
    const regBasePrice = regPrice.base.add(regPrice.premium)
    console.log('Registering directly, basePrice:', ethers.utils.formatEther(regBasePrice), 'ETN')
    // Explicit gas limit: an earlier attempt hit exactly its auto-estimated limit and reverted
    // out of gas, so we're overriding rather than trusting eth_estimateGas here.
    const registerTx = await controller.register(registration, { value: regBasePrice, gasLimit: 600000 })
    await registerTx.wait()
    console.log('Registered directly (no brokerage paid).')

    console.log('Wrapping...')
    const registrarId = ethers.BigNumber.from(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(LABEL)))
    const approveTx = await baseRegistrar.approve(NAME_WRAPPER_ADDRESS, registrarId, { gasLimit: 150000 })
    await approveTx.wait()
    const wrapTx = await nameWrapper.wrapETH2LD(LABEL, signerAddress, 0, PUBLIC_RESOLVER_ADDRESS, { gasLimit: 500000 })
    await wrapTx.wait()
    console.log(`"${LABEL}.etn" is now wrapped and owned by ${signerAddress}, but NOT activated.`)

    // --- Step 2: activateDomain on the marketplace ---
    // Fee is based on NameWrapper's actual stored expiry, NOT the original registration DURATION
    // — NameWrapper adds a grace period on top of the raw registrar expiry when it wraps, so the
    // real remaining time (and therefore the real fee) is longer than DURATION alone would
    // suggest. Basing the estimate on DURATION caused "Insufficient payment" here previously.
    const data = await nameWrapper.getData(ethers.BigNumber.from(node))
    const currentBlock = await provider.getBlock('latest')
    const remaining = data.expiry.sub(currentBlock.timestamp)
    console.log('actual expiry:', data.expiry.toString(), '| remaining seconds:', remaining.toString())

    const activationPrice = await controller.rentPrice(LABEL, remaining)
    const activationBasePrice = activationPrice.base.add(activationPrice.premium)
    const brokerageBps = await marketplace.brokerageBps()
    // +5% buffer over the estimate, since a few seconds pass before this actually mines (excess
    // is refunded automatically regardless).
    const feeEstimate = activationBasePrice.mul(brokerageBps).div(10000).mul(105).div(100)
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
