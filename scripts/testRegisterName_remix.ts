// Test tx: registers a name through the deployed marketplace's registerName() on Electroneum
// testnet. Exercises the real ETHRegistrarController + NameWrapper, not mocks.
//
// Before running:
//  1. Change LABEL below if you want a specific name (must not already be registered).
//  2. In "Deploy & Run Transactions", set Environment to "Injected Provider - MetaMask", with
//     MetaMask connected to Electroneum Testnet (chain id 5201420) and funded with testnet ETN.
//  3. Right click this file in the file explorer -> "Run".

import { ethers } from 'ethers'

const MARKETPLACE_ADDRESS = '0xFE8a448D84272Cb363F85B9B9E404Bde92350840'
const REGISTRAR_CONTROLLER_ADDRESS = '0x5BFb2958062Ac12d2019Ac1E69243DDbafCCc2c5'

// namehash("etn") — confirmed directly on-chain: ENSRegistry.owner(this node) returns exactly
// BaseRegistrarImplementation's address (0x7b787b31Ad58D563D7B3938b4bbfAB2c588624C5), while
// namehash("eth") has no owner at all. Electroneum's ENS fork uses its own TLD, not "eth".
const ETH_NODE = '0x69a3977d40595dbc343e3fa6ddbd26dbe31cc237836622384941b3c5148974cd'

const LABEL = 'zephyrostest1' // TODO: change if this is already taken
const DURATION = 30 * 24 * 60 * 60 // 30 days — safely above the registrar's 28-day minimum

const MARKETPLACE_ABI = [
  'function computeCommitment(string label, uint256 duration, bytes32 secret, bytes32 referrer) view returns (bytes32)',
  'function quoteRegistration(string label, uint256 duration) view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalPrice)',
  'function registerName(string label, uint256 duration, bytes32 secret, bytes32 referrer, address wrappedOwner, uint16 ownerControlledFuses, bytes32 expectedNode) payable returns (uint64 expiry)',
]
const CONTROLLER_ABI = [
  'function commit(bytes32 commitment) external',
  'function minCommitmentAge() view returns (uint256)',
  'function available(string label) returns (bool)',
]

function computeExpectedNode(label: string): string {
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

    const marketplace = new ethers.Contract(MARKETPLACE_ADDRESS, MARKETPLACE_ABI, signer)
    const controller = new ethers.Contract(REGISTRAR_CONTROLLER_ADDRESS, CONTROLLER_ABI, signer)

    console.log(`Registering "${LABEL}" for ${signerAddress}`)

    const isAvailable = await controller.callStatic.available(LABEL)
    if (!isAvailable) {
      throw new Error(`"${LABEL}" is not available — change LABEL and try again.`)
    }

    const secret = ethers.utils.hexlify(ethers.utils.randomBytes(32))
    const referrer = ethers.constants.HashZero

    const commitment = await marketplace.computeCommitment(LABEL, DURATION, secret, referrer)
    console.log('Commitment:', commitment)

    console.log('Submitting commit()...')
    const commitTx = await controller.commit(commitment)
    await commitTx.wait()

    const minCommitmentAge = await controller.minCommitmentAge()
    const waitSeconds = minCommitmentAge.toNumber() + 10 // small buffer past the minimum
    console.log(`Committed. Waiting ${waitSeconds}s (minCommitmentAge=${minCommitmentAge.toString()}s + buffer)...`)
    await sleep(waitSeconds * 1000)

    const [basePrice, brokerageFee, totalPrice] = await marketplace.quoteRegistration(LABEL, DURATION)
    console.log(
      `basePrice=${basePrice.toString()} brokerageFee=${brokerageFee.toString()} totalPrice=${totalPrice.toString()}`
    )

    const expectedNode = computeExpectedNode(LABEL)
    console.log('expectedNode:', expectedNode)

    console.log('Submitting registerName()...')
    const registerTx = await marketplace.registerName(
      LABEL,
      DURATION,
      secret,
      referrer,
      signerAddress,
      0,
      expectedNode,
      { value: totalPrice }
    )
    const receipt = await registerTx.wait()
    console.log(`Registered! tx: ${receipt.transactionHash}`)
    console.log(`"${LABEL}" is now wrapped and owned by ${signerAddress}, and activated for subname listings.`)
  } catch (e) {
    console.log(e.message)
  }
})()
