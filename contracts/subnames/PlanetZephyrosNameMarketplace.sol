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
 *  2) Subname / resale marketplace: once a buyer owns a wrapped name, they can list subnames of
 *     it for sale (newly created on purchase via NameWrapper.setSubnodeRecord), or list an
 *     already-wrapped name/subname they own for resale. Every such sale splits 80% to the seller
 *     and 20% into a pool that is periodically swapped for CORE and burned via CORE.burn().
 *
 * Website: https://planetzephyros.xyz/
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/IETHRegistrarController.sol";
import "./interfaces/IPriceOracle.sol";
import "./interfaces/INameWrapperLite.sol";
import "./interfaces/IBurnableERC20.sol";
import "./interfaces/IUniswapV2Router02Lite.sol";

contract PlanetZephyrosNameMarketplace is Ownable, ReentrancyGuard {
    // ========================
    // Immutable protocol wiring
    // ========================
    IETHRegistrarController public immutable registrarController;
    INameWrapperLite public immutable nameWrapper;
    IERC721 public immutable baseRegistrar;

    // ========================
    // Fee configuration
    // ========================
    uint256 private constant BPS_DENOM = 10000;
    uint256 public constant SELLER_BPS = 8000; // 80% to seller on every marketplace sale
    uint256 public constant BURN_BPS = 2000; // 20% into the CORE buyback/burn pool
    uint256 public constant MAX_BROKERAGE_BPS = 5000; // 50% hard ceiling

    /// @notice Brokerage surcharge on top of the registrar's own price, kept as project revenue.
    uint256 public brokerageBps = 2000; // 20% default

    address public defaultResolver;
    address payable public projectWallet;

    address public coreToken;
    address public swapRouter;

    uint256 public burnPool;
    uint256 public totalCoreBurned;

    bool public paused;

    // ========================
    // Marketplace listings
    // ========================
    enum ListingKind {
        NewSubname,
        ExistingWrappedName
    }

    struct Listing {
        address seller;
        ListingKind kind;
        bytes32 parentNode; // NewSubname only
        string label; // NewSubname only
        uint256 tokenId; // ExistingWrappedName only
        uint32 fuses; // NewSubname only
        uint64 expiry; // NewSubname only; 0 = inherit parent's expiry
        uint256 price;
        bool active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

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
    event SubnameListed(uint256 indexed listingId, address indexed seller, bytes32 parentNode, string label, uint256 price);
    event ExistingNameListed(uint256 indexed listingId, address indexed seller, uint256 indexed tokenId, uint256 price);
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
        baseRegistrar = IERC721(_baseRegistrar);
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
    /// waited out the registrar's minCommitmentAge.
    function registerName(
        string calldata label,
        uint256 duration,
        bytes32 secret,
        bytes32 referrer,
        address wrappedOwner,
        uint16 ownerControlledFuses
    ) external payable nonReentrant whenNotPaused returns (uint64 expiry) {
        require(wrappedOwner != address(0), "Zero wrapped owner");

        IETHRegistrarController.Registration memory registration = buildRegistration(label, duration, secret, referrer);

        IPriceOracle.Price memory p = registrarController.rentPrice(label, duration);
        uint256 basePrice = p.base + p.premium;
        uint256 brokerageFee = (basePrice * brokerageBps) / BPS_DENOM;
        uint256 totalRequired = basePrice + brokerageFee;
        require(msg.value >= totalRequired, "Insufficient payment");

        uint256 tokenId = uint256(keccak256(bytes(label)));

        registrarController.register{value: basePrice}(registration);

        // This contract is now the raw registrant; approve NameWrapper and wrap straight to the buyer.
        baseRegistrar.approve(address(nameWrapper), tokenId);
        expiry = nameWrapper.wrapETH2LD(label, wrappedOwner, ownerControlledFuses, defaultResolver);

        if (brokerageFee > 0) {
            (bool ok, ) = projectWallet.call{value: brokerageFee}("");
            require(ok, "Brokerage transfer failed");
        }

        uint256 refund = msg.value - totalRequired;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }

        emit NameRegistered(msg.sender, label, basePrice, brokerageFee, wrappedOwner, ownerControlledFuses);
    }

    // ========================================================
    // Flow B: subname + resale marketplace
    // ========================================================

    /// @notice Lists a brand-new subname of `parentNode` for sale. Caller must currently control
    /// `parentNode` in NameWrapper and must have called
    /// nameWrapper.setApprovalForAll(marketplace, true) so this contract can create the subname
    /// on purchase.
    function listSubname(
        bytes32 parentNode,
        string calldata label,
        uint32 fuses,
        uint64 expiry,
        uint256 price
    ) external whenNotPaused returns (uint256 listingId) {
        require(price > 0, "Price required");
        require(nameWrapper.canModifyName(parentNode, msg.sender), "Not parent owner/operator");
        require(nameWrapper.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            kind: ListingKind.NewSubname,
            parentNode: parentNode,
            label: label,
            tokenId: 0,
            fuses: fuses,
            expiry: expiry,
            price: price,
            active: true
        });

        emit SubnameListed(listingId, msg.sender, parentNode, label, price);
    }

    /// @notice Lists an already-wrapped name/subname the caller owns for resale. Caller must
    /// have called nameWrapper.setApprovalForAll(marketplace, true).
    function listExistingName(uint256 tokenId, uint256 price) external whenNotPaused returns (uint256 listingId) {
        require(price > 0, "Price required");
        require(nameWrapper.ownerOf(tokenId) == msg.sender, "Not token owner");
        require(nameWrapper.isApprovedForAll(msg.sender, address(this)), "Marketplace not approved");

        listingId = nextListingId++;
        listings[listingId] = Listing({
            seller: msg.sender,
            kind: ListingKind.ExistingWrappedName,
            parentNode: bytes32(0),
            label: "",
            tokenId: tokenId,
            fuses: 0,
            expiry: 0,
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

    /// @notice Buys an active listing. For NewSubname listings this creates and wraps the
    /// subname directly to the buyer; for ExistingWrappedName listings this transfers the
    /// existing NameWrapper token from seller to buyer. Every sale splits 80% seller / 20% burn
    /// pool.
    function buyListing(uint256 listingId) external payable nonReentrant whenNotPaused {
        Listing storage l = listings[listingId];
        require(l.active, "Not active");
        require(msg.value >= l.price, "Insufficient payment");

        address seller = l.seller;
        uint256 price = l.price;
        l.active = false; // effects before interactions

        if (l.kind == ListingKind.NewSubname) {
            require(nameWrapper.canModifyName(l.parentNode, seller), "Seller lost parent control");
            require(nameWrapper.isApprovedForAll(seller, address(this)), "Approval revoked");

            uint64 expiry = l.expiry;
            if (expiry == 0) {
                (, , uint64 parentExpiry) = nameWrapper.getData(uint256(l.parentNode));
                expiry = parentExpiry;
            }

            nameWrapper.setSubnodeRecord(l.parentNode, l.label, msg.sender, defaultResolver, 0, l.fuses, expiry);
        } else {
            nameWrapper.safeTransferFrom(seller, msg.sender, l.tokenId, 1, "");
        }

        uint256 sellerAmount = (price * SELLER_BPS) / BPS_DENOM;
        uint256 burnAmount = price - sellerAmount;
        burnPool += burnAmount;

        (bool ok, ) = payable(seller).call{value: sellerAmount}("");
        require(ok, "Seller payment failed");

        uint256 refund = msg.value - price;
        if (refund > 0) {
            (bool ok2, ) = payable(msg.sender).call{value: refund}("");
            require(ok2, "Refund failed");
        }

        emit ListingSold(listingId, msg.sender, seller, price, sellerAmount, burnAmount);
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
