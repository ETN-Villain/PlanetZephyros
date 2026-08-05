// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/**
 * Planet Zephyros Name Marketplace
 *
 * A wrap-around service for Electroneum's ENS-fork naming system.
 *
 *  1) Registration brokerage: buyers register a new .etn name through this contract instead of
 *     calling ETHRegistrarController directly. This contract forwards the exact base price to
 *     the registrar, wraps the resulting name via NameWrapper straight into the buyer's wallet,
 *     and keeps a configurable brokerage fee on top (100% project revenue).
 *
 *  2) Subname self-serve registration + resale: once a buyer owns a wrapped name, they can set a
 *     price for anyone to self-register a subname of it (buyer picks the label, created on
 *     payment via NameWrapper.setSubnodeRecord), or list an already-wrapped name/subname they
 *     own for resale. Every such sale splits 80% to the seller and 20% into a pool that is
 *     periodically swapped for CORE and burned via CORE.burn().
 *
 * Website: https://planetzephyros.xyz/
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IETHRegistrarController.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/INameWrapperLite.sol";
import "./interfaces/IBurnableERC20.sol";
import "./interfaces/IUniswapV2Router02Lite.sol";
import "./interfaces/IBaseRegistrarLite.sol";

contract PlanetZephyrosNameMarketplace is Ownable, ReentrancyGuard {
    // ========================
    // Immutable protocol wiring
    // ========================
    IETHRegistrarController public immutable registrarController;
    INameWrapperLite public immutable nameWrapper;
    IBaseRegistrarLite public immutable baseRegistrar;

    // ========================
    // Fee configuration
    // ========================
    uint256 private constant BPS_DENOM = 10000;
    uint256 public constant SELLER_BPS = 8000; // 80% to seller on every marketplace sale
    uint256 public constant BURN_BPS = 2000; // 20% into the CORE buyback/burn pool
    uint256 public constant MAX_BROKERAGE_BPS = 5000; // 50% hard ceiling

    /// @notice Brokerage surcharge on top of the registrar's own price, kept as project revenue.
    uint256 public brokerageBps = 5000; // 50% default

    address public defaultResolver;
    address payable public projectWallet;

    address public coreToken;
    address public swapRouter;

    uint256 public burnPool;
    uint256 public totalCoreBurned;

    bool public paused;

    // ========================
    // Domain activation
    // ========================
    /// @notice Nodes that have paid their way into the marketplace, either by registering
    /// through registerName, by having a subname created through registerSubname (fee already
    /// captured in that sale's 80/20 split), or via a retroactive activateDomain payment.
    /// setSubnamePrice/listExistingName require this before a node can be used in the marketplace.
    mapping(bytes32 => bool) public domainActivated;

    // ========================
    // Marketplace listings (resale of an already-wrapped name/subname)
    // ========================
    struct Listing {
        address seller;
        uint256 tokenId;
        uint256 price;
        bool active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    // ========================
    // Subname self-serve registration
    // ========================
    /// @notice Price (in wei) the parent domain owner charges for anyone to self-register a
    /// subname under their domain. 0 means not for sale.
    mapping(bytes32 => uint256) public subnamePrice;

    // ========================
    // Events
    // ========================
    event NameRegistered(
        address indexed buyer,
        string label,
        uint256 basePrice,
        uint256 brokerageFee,
        address wrappedTo,
        uint16 fuses
    );
    event ExistingNameListed(uint256 indexed listingId, address indexed seller, uint256 indexed tokenId, uint256 price);
    event SubnamePriceSet(bytes32 indexed parentNode, uint256 price);
    event SubnameRegistered(bytes32 indexed parentNode, string label, address indexed buyer, uint256 price, uint256 sellerAmount, uint256 burnAmount);
    event ListingCancelled(uint256 indexed listingId);
    event ListingSold(uint256 indexed listingId, address indexed buyer, address indexed seller, uint256 price, uint256 sellerAmount, uint256 burnAmount);
    event BrokerageBpsUpdated(uint256 brokerageBps);
    event ProjectWalletUpdated(address projectWallet);
    event DefaultResolverUpdated(address resolver);
    event CoreTokenUpdated(address coreToken);
    event SwapRouterUpdated(address swapRouter);
    event PausedUpdated(bool paused);
    event BuybackAndBurn(uint256 etnSpent, uint256 coreBurned);
    event TokensRescued(address token, uint256 amount, address to);
    event DomainActivated(bytes32 indexed node, address indexed payer, uint256 feePaid);
    event NameRenewed(address indexed payer, string label, uint256 basePrice, uint256 brokerageFee, uint256 newExpiry);

    modifier whenNotPaused() {
        require(!paused, "Marketplace paused");
        _;
    }

    constructor(
        address _registrarController,
        address _nameWrapper,
        address _baseRegistrar,
        address _defaultResolver,
        address payable _projectWallet,
        address _owner
    ) Ownable(_owner) {
        require(_registrarController != address(0), "Zero registrar controller");
        require(_nameWrapper != address(0), "Zero name wrapper");
        require(_baseRegistrar != address(0), "Zero base registrar");
        require(_projectWallet != address(0), "Zero project wallet");

        registrarController = IETHRegistrarController(_registrarController);
        nameWrapper = INameWrapperLite(_nameWrapper);
        baseRegistrar = IBaseRegistrarLite(_baseRegistrar);
        defaultResolver = _defaultResolver;
        projectWallet = _projectWallet;
    }

    // ========================================================
    // Flow A: registration brokerage
    // ========================================================

    /// @notice Builds the Registration struct a buyer must hash (via computeCommitment) and
    /// commit on ETHRegistrarController directly, before calling registerName here. Owner is
    /// forced to this contract because it must temporarily hold the raw name to wrap it;
    /// resolver/data/reverseRecord are forced off because proxying them through this contract's
    /// commit-reveal cycle cannot be proven safe against the registrar's own record-setting
    /// authorisation checks — buyers set resolver records themselves after they own the wrapped
    /// name.
    function buildRegistration(
        string calldata label,
        uint256 duration,
        bytes32 secret,
        bytes32 referrer
    ) public view returns (IETHRegistrarController.Registration memory registration) {
        registration = IETHRegistrarController.Registration({
            label: label,
            owner: address(this),
            duration: duration,
            secret: secret,
            resolver: address(0),
            data: new bytes[](0),
            reverseRecord: 0,
            referrer: referrer
        });
    }

    /// @notice Convenience view so integrators don't need to hardcode this contract's address
    /// client-side when building the commitment to pass to ETHRegistrarController.commit().
    function computeCommitment(
        string calldata label,
        uint256 duration,
        bytes32 secret,
        bytes32 referrer
    ) external view returns (bytes32) {
        return registrarController.makeCommitment(buildRegistration(label, duration, secret, referrer));
    }

    /// @notice Quotes the registrar's own price plus this contract's brokerage fee.
    function quoteRegistration(
        string calldata label,
        uint256 duration
    ) external view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalPrice) {
        IPriceOracle.Price memory p = registrarController.rentPrice(label, duration);
        basePrice = p.base + p.premium;
        brokerageFee = (basePrice * brokerageBps) / BPS_DENOM;
        totalPrice = basePrice + brokerageFee;
    }

    /// @notice Registers a name via ETHRegistrarController and wraps it directly to
    /// `wrappedOwner`. Caller must have already called ETHRegistrarController.commit() with the
    /// exact commitment returned by computeCommitment(label, duration, secret, referrer), and
    /// waited out the registrar's minCommitmentAge. `expectedNode` is the wrapped name's ENS
    /// node (e.g. ethers.namehash("label.<tld>") computed off-chain) — this contract verifies it
    /// against NameWrapper's own record after wrapping, rather than assuming any particular
    /// root/TLD itself, and marks it activated so setSubnamePrice/listExistingName work
    /// immediately.
    function registerName(
        string calldata label,
        uint256 duration,
        bytes32 secret,
        bytes32 referrer,
        address wrappedOwner,
        uint16 ownerControlledFuses,
        bytes32 expectedNode
    ) external payable nonReentrant whenNotPaused returns (uint64 expiry) {
        require(wrappedOwner != address(0), "Zero wrapped owner");

        (uint256 basePrice, uint256 brokerageFee, uint256 totalRequired) = _quoteRegistrationChecked(label, duration);

        registrarController.register{value: basePrice}(buildRegistration(label, duration, secret, referrer));

        expiry = _wrapAndActivate(label, wrappedOwner, ownerControlledFuses, expectedNode);

        _settleRegistration(brokerageFee, totalRequired);

        emit NameRegistered(msg.sender, label, basePrice, brokerageFee, wrappedOwner, ownerControlledFuses);
    }

    /// @dev Split out of registerName purely to keep that function's stack usage low enough to
    /// compile without viaIR (Remix's default codegen). Mirrors quoteRegistration's math.
    function _quoteRegistrationChecked(
        string calldata label,
        uint256 duration
    ) internal view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalRequired) {
        IPriceOracle.Price memory p = registrarController.rentPrice(label, duration);
        basePrice = p.base + p.premium;
        brokerageFee = (basePrice * brokerageBps) / BPS_DENOM;
        totalRequired = basePrice + brokerageFee;
        require(msg.value >= totalRequired, "Insufficient payment");
    }

    /// @dev Split out of registerName for the same reason as _quoteRegistrationChecked. This
    /// contract is the raw registrant at this point; approve NameWrapper and wrap straight to
    /// the buyer, then verify/activate expectedNode.
    function _wrapAndActivate(
        string calldata label,
        address wrappedOwner,
        uint16 ownerControlledFuses,
        bytes32 expectedNode
    ) internal returns (uint64 expiry) {
        uint256 tokenId = uint256(keccak256(bytes(label)));
        baseRegistrar.approve(address(nameWrapper), tokenId);
        expiry = nameWrapper.wrapETH2LD(label, wrappedOwner, ownerControlledFuses, defaultResolver);

        require(_firstLabelMatches(nameWrapper.names(expectedNode), label), "expectedNode mismatch");
        domainActivated[expectedNode] = true;
    }

    /// @dev Split out of registerName for the same reason as _quoteRegistrationChecked.
    function _settleRegistration(uint256 brokerageFee, uint256 totalRequired) internal {
        if (brokerageFee > 0) {
            (bool ok, ) = projectWallet.call{value: brokerageFee}("");
            require(ok, "Brokerage transfer failed");
        }

        uint256 refund = msg.value - totalRequired;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }
    }

    /// @notice Quotes the registrar's own renewal price plus this contract's brokerage fee.
    /// Renewals never carry a premium (unlike fresh registrations) — the real registrar's
    /// renew() only ever checks against price.base, so this mirrors that exactly rather than
    /// reusing quoteRegistration's base+premium math.
    function quoteRenewal(
        string calldata label,
        uint256 duration
    ) external view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalPrice) {
        IPriceOracle.Price memory p = registrarController.rentPrice(label, duration);
        basePrice = p.base;
        brokerageFee = (basePrice * brokerageBps) / BPS_DENOM;
        totalPrice = basePrice + brokerageFee;
    }

    /// @notice Renews a name via ETHRegistrarController, forwarding the exact base renewal
    /// price and keeping a brokerage fee on top, same revenue model as registerName. Anyone can
    /// renew any name (matching the real registrar's own renew(), which isn't ownership-gated).
    function renewName(
        string calldata label,
        uint256 duration,
        bytes32 referrer
    ) external payable nonReentrant whenNotPaused returns (uint256 newExpiry) {
        (uint256 basePrice, uint256 brokerageFee, uint256 totalRequired) = _quoteRenewalChecked(label, duration);

        registrarController.renew{value: basePrice}(label, duration, referrer);
        newExpiry = baseRegistrar.nameExpires(uint256(keccak256(bytes(label))));

        _settleRenewal(brokerageFee, totalRequired);

        emit NameRenewed(msg.sender, label, basePrice, brokerageFee, newExpiry);
    }

    /// @dev Split out of renewName for the same stack-depth reason as the registration helpers.
    /// Mirrors quoteRenewal's math.
    function _quoteRenewalChecked(
        string calldata label,
        uint256 duration
    ) internal view returns (uint256 basePrice, uint256 brokerageFee, uint256 totalRequired) {
        IPriceOracle.Price memory p = registrarController.rentPrice(label, duration);
        basePrice = p.base;
        brokerageFee = (basePrice * brokerageBps) / BPS_DENOM;
        totalRequired = basePrice + brokerageFee;
        require(msg.value >= totalRequired, "Insufficient payment");
    }

    /// @dev Split out of renewName for the same reason as _quoteRenewalChecked.
    function _settleRenewal(uint256 brokerageFee, uint256 totalRequired) internal {
        if (brokerageFee > 0) {
            (bool ok, ) = projectWallet.call{value: brokerageFee}("");
            require(ok, "Brokerage transfer failed");
        }

        uint256 refund = msg.value - totalRequired;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }
    }

    /// @notice Retroactively activates a name that was registered directly with
    /// ETHRegistrarController (bypassing this marketplace's brokerage), so its owner can start
    /// using setSubnamePrice/listExistingName. Fee is brokerageBps of what the registrar would
    /// charge today to register this exact name for however much time is actually left on it
    /// (read from NameWrapper), so it can't be gamed by under-declaring duration.
    function activateDomain(
        bytes32 node,
        string calldata label
    ) external payable nonReentrant whenNotPaused returns (uint256 fee) {
        require(nameWrapper.ownerOf(uint256(node)) == msg.sender, "Not name owner");
        require(!domainActivated[node], "Already activated");
        require(_firstLabelMatches(nameWrapper.names(node), label), "Label mismatch");

        fee = _activationFee(node, label);
        require(msg.value >= fee, "Insufficient payment");

        domainActivated[node] = true;
        _settleActivation(fee);

        emit DomainActivated(node, msg.sender, fee);
    }

    /// @dev Split out of activateDomain to keep its stack usage low enough to compile without
    /// viaIR (Remix's default codegen).
    function _activationFee(bytes32 node, string calldata label) internal view returns (uint256 fee) {
        (, , uint64 expiry) = nameWrapper.getData(uint256(node));
        require(expiry > block.timestamp, "Name expired");
        uint256 remaining = uint256(expiry) - block.timestamp;

        IPriceOracle.Price memory p = registrarController.rentPrice(label, remaining);
        uint256 basePrice = p.base + p.premium;
        fee = (basePrice * brokerageBps) / BPS_DENOM;
    }

    /// @dev Split out of activateDomain for the same reason as _activationFee.
    function _settleActivation(uint256 fee) internal {
        if (fee > 0) {
            (bool ok, ) = projectWallet.call{value: fee}("");
            require(ok, "Activation fee transfer failed");
        }

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }
    }

    /// @dev Compares the first (leftmost) DNS-wire-encoded label in `encoded` against `label`,
    /// without assuming anything about what follows it (the TLD/root). Used to verify a
    /// caller-supplied node/label pair against NameWrapper's own authoritative record.
    function _firstLabelMatches(bytes memory encoded, string calldata label) internal pure returns (bool) {
        bytes memory labelBytes = bytes(label);
        if (encoded.length < 1 + labelBytes.length) return false;
        if (uint8(encoded[0]) != labelBytes.length) return false;
        for (uint256 i = 0; i < labelBytes.length; i++) {
            if (encoded[1 + i] != labelBytes[i]) return false;
        }
        return true;
    }

    // ========================================================
    // Flow B: subname self-serve registration + resale marketplace
    // ========================================================

    /// @notice Sets (or clears, with price=0) the price for self-serve subname registration
    /// under a domain the caller owns/controls. Requires the domain to already be activated.
    function setSubnamePrice(bytes32 parentNode, uint256 price) external whenNotPaused {
        require(domainActivated[parentNode], "Domain not activated");
        require(nameWrapper.canModifyName(parentNode, msg.sender), "Not parent owner/operator");
        subnamePrice[parentNode] = price;
        emit SubnamePriceSet(parentNode, price);
    }

    /// @notice Self-serve subname registration: buyer picks the label, pays the parent owner's
    /// set price, and the subname is created and wrapped directly to the buyer. Same 80/20
    /// seller/burn split as buyListing, via _settleSale. The new subname is itself immediately
    /// activated, so its new owner can set their own subname price / resell it right away.
    function registerSubname(
        bytes32 parentNode,
        string calldata label
    ) external payable nonReentrant whenNotPaused returns (bytes32 subNode) {
        uint256 price = subnamePrice[parentNode];
        require(price > 0, "Subnames not for sale");
        require(msg.value >= price, "Insufficient payment");

        address seller = nameWrapper.ownerOf(uint256(parentNode));
        subNode = _fulfillSubname(parentNode, label, seller);

        (uint256 sellerAmount, uint256 burnAmount) = _settleSale(seller, price);

        emit SubnameRegistered(parentNode, label, msg.sender, price, sellerAmount, burnAmount);
    }

    /// @dev Split out of registerSubname to keep its stack usage low enough to compile without
    /// viaIR (Remix's default codegen).
    function _fulfillSubname(
        bytes32 parentNode,
        string calldata label,
        address seller
    ) internal returns (bytes32 subNode) {
        require(nameWrapper.canModifyName(parentNode, seller), "Parent owner lost control");
        require(nameWrapper.isApprovedForAll(seller, address(this)), "Marketplace not approved by parent owner");

        (, , uint64 expiry) = nameWrapper.getData(uint256(parentNode));
        subNode = nameWrapper.setSubnodeRecord(parentNode, label, msg.sender, defaultResolver, 0, 0, expiry);
        domainActivated[subNode] = true;
    }

    /// @notice Lists an already-wrapped name/subname the caller owns for resale. Caller must
    /// have called nameWrapper.setApprovalForAll(marketplace, true).
    function listExistingName(uint256 tokenId, uint256 price) external whenNotPaused returns (uint256 listingId) {
        require(price > 0, "Price required");
        require(domainActivated[bytes32(tokenId)], "Domain not activated");
        require(nameWrapper.ownerOf(tokenId) == msg.sender, "Not token owner");
        require(nameWrapper.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            tokenId: tokenId,
            price: price,
            active: true
        });

        emit ExistingNameListed(listingId, msg.sender, tokenId, price);
    }

    function cancelListing(uint256 listingId) external {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        require(l.seller == msg.sender || msg.sender == owner(), "Not authorised");
        l.active = false;
        emit ListingCancelled(listingId);
    }

    /// @notice Buys an active listing, transferring the existing NameWrapper token from seller
    /// to buyer. Every sale splits 80% seller / 20% burn pool.
    function buyListing(uint256 listingId) external payable nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        require(msg.value >= l.price, "Insufficient payment");

        address seller = l.seller;
        uint256 price = l.price;
        l.active = false; // effects before interactions

        nameWrapper.safeTransferFrom(seller, msg.sender, l.tokenId, 1, "");

        (uint256 sellerAmount, uint256 burnAmount) = _settleSale(seller, price);

        emit ListingSold(listingId, msg.sender, seller, price, sellerAmount, burnAmount);
    }

    /// @dev Split out of buyListing/registerSubname for the same stack-depth reason as the other
    /// flows.
    function _settleSale(address seller, uint256 price) internal returns (uint256 sellerAmount, uint256 burnAmount) {
        sellerAmount = (price * SELLER_BPS) / BPS_DENOM;
        burnAmount = price - sellerAmount;
        burnPool += burnAmount;

        (bool ok, ) = payable(seller).call{value: sellerAmount}("");
        require(ok, "Seller payment failed");

        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }
    }

    // ========================================================
    // CORE buyback and burn
    // ========================================================

    /// @notice Swaps the accumulated burn pool for CORE and burns it via CORE.burn(). Owner-only
    /// and slippage-guarded by the caller-supplied minCoreOut, matching the manual-trigger
    /// pattern already used by this repo's other fee-reflection contracts.
    function buyBackAndBurn(uint256 minCoreOut, uint256 deadline) external onlyOwner nonReentrant {
        require(coreToken != address(0) && swapRouter != address(0), "Buyback not configured");
        uint256 amount = burnPool;
        require(amount > 0, "Nothing to burn");
        burnPool = 0;

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02Lite(swapRouter).WETH();
        path[1] = coreToken;

        uint256 balanceBefore = IERC20(coreToken).balanceOf(address(this));

        IUniswapV2Router02Lite(swapRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            minCoreOut,
            path,
            address(this),
            deadline
        );

        uint256 received = IERC20(coreToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "Swap failed");

        IBurnableERC20(coreToken).burn(received);
        totalCoreBurned += received;

        emit BuybackAndBurn(amount, received);
    }

    // ========================================================
    // Admin
    // ========================================================

    function setBrokerageBps(uint256 _brokerageBps) external onlyOwner {
        require(_brokerageBps <= MAX_BROKERAGE_BPS, "Brokerage too high");
        brokerageBps = _brokerageBps;
        emit BrokerageBpsUpdated(_brokerageBps);
    }

    function setProjectWallet(address payable _projectWallet) external onlyOwner {
        require(_projectWallet != address(0), "Zero address");
        projectWallet = _projectWallet;
        emit ProjectWalletUpdated(_projectWallet);
    }

    function setDefaultResolver(address _resolver) external onlyOwner {
        defaultResolver = _resolver;
        emit DefaultResolverUpdated(_resolver);
    }

    function setCoreToken(address _coreToken) external onlyOwner {
        coreToken = _coreToken;
        emit CoreTokenUpdated(_coreToken);
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(_swapRouter);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedUpdated(_paused);
    }

    /// @notice Rescues ERC20 tokens accidentally sent to this contract. The burn pool is held as
    /// native ETN, not ERC20, so this never touches marketplace funds.
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), "Zero address");
        require(IERC20(token).transfer(to, amount), "Rescue transfer failed");
        emit TokensRescued(token, amount, to);
    }
}
