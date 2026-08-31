// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/**
 * Premium Subscription
 *
 * Premium Feature #1 for the Electroneum dashboard (dashboard.planetzephyros.xyz — see
 * ETNSubdomainService repo). Pure payment/pricing/access/execution layer: this contract does NOT
 * track the PnL statement request lifecycle (PAID/PENDING_GENERATION/GENERATED/FINALIZED) — that
 * state machine lives in the dashboard backend's own database, driven by the events this contract
 * emits. This contract only ever escrows funds and, once told to by the trusted operator,
 * executes the buy-and-burn split or a refund.
 *
 *  1) Membership, two independent tiers:
 *     - subscribe() sells monthly membership (membershipExpiry). Currently unlocks nothing on its
 *       own — kept for future premium features to gate on isMembershipActive().
 *     - subscribeAnnual() sells annual-tier membership (annualMembershipExpiry) — a SEPARATE,
 *       structurally-larger commitment, tracked separately from monthly on purpose: it's the only
 *       membership tier that discounts PnL statements (see isEligibleForDiscount). A cheap
 *       one-month monthly signup must never come close to qualifying for the same discount an
 *       annual subscriber pays for — that's the whole reason these are two different mappings
 *       instead of one "isMembershipActive means discount" check.
 *
 *  2) PnL statement periods: purchasePnlPeriods() is open to any caller, not gated on membership.
 *     Each purchase names one or more specific reporting periods (fixed calendar-year/UK/AU/US-
 *     style shapes — this contract does not validate the shape itself, only that each period's
 *     claimed end has already passed; the backend enforces the shape is one of the real four
 *     before ever accepting a generation request for it, since it already needs the same calendar
 *     logic to slice the FIFO ledger). Base price is pnlPricePerPeriod per period.
 *
 *     Discount model (confirmed design — see PR discussion, not guessed):
 *       - 50% off EVERY period in the purchase if isEligibleForDiscount(msg.sender) is true
 *         (active ANNUAL membership, the whitelist, or an ErevosShares NFT if that path is
 *         enabled) OR the caller proves ownership of a specific activated domain via
 *         activatedDomainNode (isActivatedDomainOwner, if that path is enabled).
 *       - Otherwise (no discount path applies): the FIRST period in the purchase is full price,
 *         and every SUBSEQUENT period in that same purchase is 2/3 price (33% off) — a multi-buy
 *         incentive, not a discount-path perk. These two discount mechanisms never stack: a
 *         discount-eligible caller pays the flat 50% price for every period, full stop, with no
 *         additional multi-buy reduction layered on top.
 *
 *     Funds (when non-zero) stay escrowed in this contract; nothing is split here — the dashboard
 *     backend's watcher reads the per-period PnlPeriodPurchased events to create statement
 *     requests, and later calls executeSplitForPeriod once its own state machine reaches
 *     FINALIZED for a given request — this contract has no visibility into that state machine and
 *     trusts the operator's `amount` on that call.
 *
 *  3) Buy-and-burn: executeSplitForPeriod copies, unmodified, the proven swap-and-burn pattern
 *     already live in this repo's PlanetZephyrosSubdomainNameServiceV3.buyBackAndBurn() — half of
 *     whatever's released goes straight to splitDestination, the other half is swapped ETN->CORE
 *     via a Uniswap-V2-style router and burned via CORE's own burn().
 *
 * Website: https://dashboard.planetzephyros.xyz/
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import "../subnames/interfaces/IUniswapV2Router02Lite.sol";
import "../subnames/interfaces/IBurnableERC20.sol";
import "../subnames/interfaces/INameWrapperLite.sol";
import "./interfaces/IMarketplaceLite.sol";

contract PlanetZephyrosPnLStatement is Ownable, ReentrancyGuard {
    // ========================
    // Roles
    // ========================
    /// @notice The dashboard backend's trusted wallet. Can only move already-escrowed PnL-period
    /// funds through the two narrow, logged paths below (executeSplitForPeriod/refundPnlPeriod) —
    /// cannot touch pricing, wiring addresses, or the pause switch. Deliberately a role separate
    /// from owner (unlike PlanetZephyrosSubdomainNameServiceV3's single-owner model) so a leaked
    /// backend key is contained to those two paths.
    address public operator;

    // ========================
    // Membership pricing (two independent tiers — see contract header)
    // ========================
    uint256 public constant SECONDS_PER_MONTH = 30 days;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Owner-adjustable ETN price per 30-day monthly membership period. Starts at 5,000
    /// ETN/mo. Does NOT grant the PnL discount — see annualMembershipPricePerYear.
    uint256 public membershipPricePerMonth = 5_000 ether;

    /// @notice Owner-adjustable ETN price per 365-day annual membership period. Starts at 40,000
    /// ETN/yr (matches the original premium-dashboard brief's annual price point). ONLY this tier
    /// grants isEligibleForDiscount's 50%-off PnL pricing.
    uint256 public annualMembershipPricePerYear = 40_000 ether;

    /// @notice Monthly membership expiry (unix timestamp) per address. 0 / in the past = inactive.
    mapping(address => uint256) public membershipExpiry;

    /// @notice Annual membership expiry (unix timestamp) per address — separate from
    /// membershipExpiry on purpose (see contract header). 0 / in the past = inactive.
    mapping(address => uint256) public annualMembershipExpiry;

    // ========================
    // PnL statement period pricing
    // ========================
    /// @notice Owner-adjustable ETN base price per statement period. Starts at 15,000 ETN.
    uint256 public pnlPricePerPeriod = 15_000 ether;

    /// @notice Sanity ceiling on how many periods one purchasePnlPeriods call can cover — avoids
    /// an unbounded loop / gas-griefing call. Comfortably above any realistic single order.
    uint256 public constant MAX_PERIODS_PER_PURCHASE = 12;

    // ========================
    // Discount grants
    // ========================
    /// @notice Owner-maintained allowlist — an address here gets the 50% PnL discount,
    /// independent of membership.
    mapping(address => bool) public whitelisted;

    /// @notice ErevosShares (mainnet: 0x120E438b5A79E447F78C7857c8E55C3674349f05, the 9-supply
    /// revenue-share NFT collection) — any holder (balanceOf > 0) gets the 50% discount when
    /// erevosDiscountEnabled is true. Unset (address(0)) disables this path regardless of the flag.
    address public erevosShares;

    /// @notice Owner on/off switch for the ErevosShares discount path, independent of whether
    /// erevosShares itself is wired — lets the owner disable the perk without clearing the address.
    bool public erevosDiscountEnabled = true;

    /// @notice The marketplace contract (PlanetZephyrosSubdomainNameServiceV3) — source of truth
    /// for domainActivated(node), used by isActivatedDomainOwner. Unset disables that path.
    address public marketplace;

    /// @notice ENS-fork NameWrapper — source of truth for who currently owns a given node, used by
    /// isActivatedDomainOwner to confirm the caller actually owns the activated domain they're
    /// claiming the discount through. Unset disables that path.
    address public nameWrapper;

    /// @notice Owner on/off switch for the activated-domain discount path, same reasoning as
    /// erevosDiscountEnabled.
    bool public activatedDomainDiscountEnabled = true;

    // ========================
    // Buy-and-burn wiring
    // ========================
    address public coreToken;
    address public swapRouter;

    /// @notice Receives the non-burn half of every executed split. Set to the same wallet as
    /// operator per this feature's confirmed design (no separate treasury address).
    address payable public splitDestination;

    uint256 public totalCoreBurned;

    bool public paused;

    // ========================
    // Period identification (informational — see contract header on why the contract doesn't
    // validate the calendar shape itself)
    // ========================
    /// @notice Which of the four fixed reporting-period shapes a purchased period represents —
    /// logged for the backend/frontend, not interpreted on-chain.
    enum PeriodType {
        CalendarYear, // Jan 1 - Dec 31
        UKStyle, // Apr 1 - Mar 31 (UK/India/Japan/Canada/South Africa)
        AUStyle, // Jul 1 - Jun 30 (Australia/NZ/Egypt/Pakistan)
        USStyle // Oct 1 - Sep 30 (US federal/Thailand)
    }

    /// @notice One period being purchased: which shape, which year identifies the specific
    /// instance of that shape (e.g. 2025), and the exact end timestamp the backend computed for
    /// it. periodEnd is the only field this contract actually validates (must already be in the
    /// past) — periodType/year are carried through purely for logging/statement-labeling.
    struct PeriodClaim {
        PeriodType periodType;
        uint16 year;
        uint64 periodEnd;
    }

    // ========================
    // Events
    // ========================
    event MembershipPurchased(address indexed subscriber, uint256 numMonths, uint256 paid, uint256 newExpiry);
    event AnnualMembershipPurchased(address indexed subscriber, uint256 numYears, uint256 paid, uint256 newExpiry);
    event PnlPeriodPurchased(
        address indexed payer,
        address indexed trackedWallet,
        PeriodType periodType,
        uint16 year,
        uint64 periodEnd,
        uint256 amountPaid
    );
    event MembershipPricePerMonthUpdated(uint256 membershipPricePerMonth);
    event AnnualMembershipPricePerYearUpdated(uint256 annualMembershipPricePerYear);
    event PnlPricePerPeriodUpdated(uint256 pnlPricePerPeriod);
    event CoreTokenUpdated(address coreToken);
    event SwapRouterUpdated(address swapRouter);
    event SplitDestinationUpdated(address splitDestination);
    event OperatorUpdated(address operator);
    event PausedUpdated(bool paused);
    event WhitelistUpdated(address indexed who, bool whitelisted);
    event ErevosSharesUpdated(address erevosShares);
    event ErevosDiscountEnabledUpdated(bool enabled);
    event MarketplaceUpdated(address marketplace);
    event NameWrapperUpdated(address nameWrapper);
    event ActivatedDomainDiscountEnabledUpdated(bool enabled);
    event PnlPeriodSplitExecuted(address indexed operator, uint256 amountSplit, address splitWallet, uint256 coreReceived, uint256 coreBurned);
    event PnlPeriodRefunded(address indexed operator, address indexed to, uint256 amount);

    // ========================
    // Modifiers
    // ========================
    modifier whenNotPaused() {
        require(!paused, "Premium subscription paused");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "Not operator");
        _;
    }

    constructor(address _owner, address _operator, address payable _splitDestination) Ownable(_owner) {
        require(_operator != address(0), "Zero operator");
        require(_splitDestination != address(0), "Zero split destination");
        operator = _operator;
        splitDestination = _splitDestination;
    }

    // ========================================================
    // Membership
    // ========================================================

    /// @notice Extends msg.sender's monthly membership by numMonths 30-day periods, from
    /// whichever is later of their current expiry or now. Excess msg.value is refunded, same
    /// convention as PlanetZephyrosSubdomainNameServiceV3's registerName/activateDomain. Does NOT
    /// grant the PnL discount — see subscribeAnnual.
    function subscribe(uint256 numMonths) external payable whenNotPaused nonReentrant {
        require(numMonths >= 1, "numMonths must be >= 1");

        uint256 required = membershipPricePerMonth * numMonths;
        require(msg.value >= required, "Insufficient payment");

        uint256 base = membershipExpiry[msg.sender] > block.timestamp ? membershipExpiry[msg.sender] : block.timestamp;
        uint256 newExpiry = base + (numMonths * SECONDS_PER_MONTH);
        membershipExpiry[msg.sender] = newExpiry;

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit MembershipPurchased(msg.sender, numMonths, required, newExpiry);
    }

    /// @notice Extends msg.sender's ANNUAL membership by numYears 365-day periods, same
    /// stack-from-later-of-expiry-or-now / excess-refund conventions as subscribe(). This is the
    /// only membership tier that grants isEligibleForDiscount's 50% PnL discount — see contract
    /// header for why monthly and annual are tracked completely separately.
    function subscribeAnnual(uint256 numYears) external payable whenNotPaused nonReentrant {
        require(numYears >= 1, "numYears must be >= 1");

        uint256 required = annualMembershipPricePerYear * numYears;
        require(msg.value >= required, "Insufficient payment");

        uint256 base = annualMembershipExpiry[msg.sender] > block.timestamp ? annualMembershipExpiry[msg.sender] : block.timestamp;
        uint256 newExpiry = base + (numYears * SECONDS_PER_YEAR);
        annualMembershipExpiry[msg.sender] = newExpiry;

        uint256 refund = msg.value - required;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Refund failed");
        }

        emit AnnualMembershipPurchased(msg.sender, numYears, required, newExpiry);
    }

    function isMembershipActive(address who) public view returns (bool) {
        return membershipExpiry[who] > block.timestamp;
    }

    function isAnnualMember(address who) public view returns (bool) {
        return annualMembershipExpiry[who] > block.timestamp;
    }

    /// @notice True if `who` gets the 50% PnL discount via annual membership, the whitelist, or
    /// holding an ErevosShares NFT (when that path is enabled) — every discount path EXCEPT
    /// activated-domain ownership, which needs a node argument and is checked separately by
    /// isActivatedDomainOwner. Public so the frontend can show the discounted price before the
    /// caller ever signs a transaction. Monthly membership (isMembershipActive) deliberately does
    /// NOT appear here — see contract header.
    function isEligibleForDiscount(address who) public view returns (bool) {
        if (isAnnualMember(who)) return true;
        if (whitelisted[who]) return true;
        if (erevosDiscountEnabled && erevosShares != address(0) && IERC721(erevosShares).balanceOf(who) > 0) return true;
        return false;
    }

    /// @notice True if the activated-domain discount path is enabled AND `who` currently owns
    /// `node` AND that node is marked activated on the marketplace. Never reverts on a bogus/
    /// unowned/zero node or a disabled/unwired path — callers (purchasePnlPeriods) are expected to
    /// fall through to isEligibleForDiscount or the full/multi-buy price instead.
    function isActivatedDomainOwner(address who, bytes32 node) public view returns (bool) {
        if (!activatedDomainDiscountEnabled) return false;
        if (marketplace == address(0) || nameWrapper == address(0) || node == bytes32(0)) return false;
        if (!IMarketplaceLite(marketplace).domainActivated(node)) return false;
        return INameWrapperLite(nameWrapper).ownerOf(uint256(node)) == who;
    }

    // ========================================================
    // PnL statement periods
    // ========================================================

    /// @notice Purchases one or more specific PnL statement periods for trackedWallet in a single
    /// order. Each entry in `periods` must have already ended (periodEnd <= now) — the contract
    /// rejects payment for a period that can't yet be fulfilled, before any generation is ever
    /// requested. Pricing per contract header: if the caller is discount-eligible (annual member,
    /// whitelisted, ErevosShares holder with that path enabled, OR proves ownership of
    /// activatedDomainNode with that path enabled), every period costs pnlPricePerPeriod / 2.
    /// Otherwise the first period in `periods` costs pnlPricePerPeriod and every period after it
    /// costs pnlPricePerPeriod * 2/3 — these two mechanisms never stack. Emits one
    /// PnlPeriodPurchased event per period (each with its own exact price paid), which is what the
    /// dashboard backend's watcher uses to create one statement request per period — never from a
    /// client-submitted claim.
    function purchasePnlPeriods(address trackedWallet, PeriodClaim[] calldata periods, bytes32 activatedDomainNode) external payable whenNotPaused nonReentrant {
        require(trackedWallet != address(0), "Zero tracked wallet");
        require(periods.length >= 1, "Must purchase at least one period");
        require(periods.length <= MAX_PERIODS_PER_PURCHASE, "Too many periods in one purchase");

        bool discounted = isEligibleForDiscount(msg.sender) || isActivatedDomainOwner(msg.sender, activatedDomainNode);
        uint256 discountedPrice = pnlPricePerPeriod / 2;
        uint256 multiBuyPrice = (pnlPricePerPeriod * 2) / 3;

        uint256 total = 0;
        for (uint256 i = 0; i < periods.length; i++) {
            require(periods[i].periodEnd <= block.timestamp, "Period has not ended yet");

            uint256 price;
            if (discounted) {
                price = discountedPrice;
            } else {
                price = (i == 0) ? pnlPricePerPeriod : multiBuyPrice;
            }
            total += price;

            emit PnlPeriodPurchased(msg.sender, trackedWallet, periods[i].periodType, periods[i].year, periods[i].periodEnd, price);
        }

        require(msg.value >= total, "Insufficient payment");

        uint256 refund = msg.value - total;
        if (refund > 0) {
            (bool ok, ) = payable(msg.sender).call{value: refund}("");
            require(ok, "Refund failed");
        }
    }

    // ========================================================
    // Operator-triggered execution (backend-driven, off-chain state machine)
    // ========================================================

    /// @notice Releases `amount` of this contract's escrowed balance: half to splitDestination,
    /// half swapped ETN->CORE and burned. Copies PlanetZephyrosSubdomainNameServiceV3's
    /// buyBackAndBurn() swap logic unmodified. The operator (dashboard backend) calls this exactly
    /// once per statement request, when its own database transitions that request to FINALIZED —
    /// this contract has no visibility into that state machine and trusts the operator's `amount`.
    function executeSplitForPeriod(uint256 amount, uint256 minCoreOut, uint256 deadline) external onlyOperator whenNotPaused nonReentrant {
        require(coreToken != address(0) && swapRouter != address(0), "Buyback not configured");
        require(amount > 0, "Nothing to split");
        require(address(this).balance >= amount, "Insufficient balance");

        uint256 toSplitWallet = amount / 2;
        uint256 toSwap = amount - toSplitWallet;

        if (toSplitWallet > 0) {
            (bool ok, ) = splitDestination.call{value: toSplitWallet}("");
            require(ok, "Split transfer failed");
        }

        address[] memory path = new address[](2);
        path[0] = IUniswapV2Router02Lite(swapRouter).WETH();
        path[1] = coreToken;

        uint256 balanceBefore = IERC20(coreToken).balanceOf(address(this));

        IUniswapV2Router02Lite(swapRouter).swapExactETHForTokensSupportingFeeOnTransferTokens{value: toSwap}(
            minCoreOut,
            path,
            address(this),
            deadline
        );

        uint256 received = IERC20(coreToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "Swap failed");

        IBurnableERC20(coreToken).burn(received);
        totalCoreBurned += received;

        emit PnlPeriodSplitExecuted(msg.sender, amount, splitDestination, received, received);
    }

    /// @notice Refunds `amount` of this contract's escrowed balance to `to`. The operator calls
    /// this when the backend's state machine allows a refund (before either finalize trigger) —
    /// same trust boundary as executeSplitForPeriod.
    function refundPnlPeriod(address payable to, uint256 amount) external onlyOperator whenNotPaused nonReentrant {
        require(to != address(0), "Zero refund destination");
        require(amount > 0, "Nothing to refund");
        require(address(this).balance >= amount, "Insufficient balance");

        (bool ok, ) = to.call{value: amount}("");
        require(ok, "Refund transfer failed");

        emit PnlPeriodRefunded(msg.sender, to, amount);
    }

    // ========================================================
    // Admin
    // ========================================================

    function setMembershipPricePerMonth(uint256 _membershipPricePerMonth) external onlyOwner {
        membershipPricePerMonth = _membershipPricePerMonth;
        emit MembershipPricePerMonthUpdated(_membershipPricePerMonth);
    }

    function setAnnualMembershipPricePerYear(uint256 _annualMembershipPricePerYear) external onlyOwner {
        annualMembershipPricePerYear = _annualMembershipPricePerYear;
        emit AnnualMembershipPricePerYearUpdated(_annualMembershipPricePerYear);
    }

    function setPnlPricePerPeriod(uint256 _pnlPricePerPeriod) external onlyOwner {
        pnlPricePerPeriod = _pnlPricePerPeriod;
        emit PnlPricePerPeriodUpdated(_pnlPricePerPeriod);
    }

    function setCoreToken(address _coreToken) external onlyOwner {
        coreToken = _coreToken;
        emit CoreTokenUpdated(_coreToken);
    }

    function setSwapRouter(address _swapRouter) external onlyOwner {
        swapRouter = _swapRouter;
        emit SwapRouterUpdated(_swapRouter);
    }

    function setSplitDestination(address payable _splitDestination) external onlyOwner {
        require(_splitDestination != address(0), "Zero split destination");
        splitDestination = _splitDestination;
        emit SplitDestinationUpdated(_splitDestination);
    }

    function setOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Zero operator");
        operator = _operator;
        emit OperatorUpdated(_operator);
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PausedUpdated(_paused);
    }

    function setWhitelisted(address who, bool value) external onlyOwner {
        whitelisted[who] = value;
        emit WhitelistUpdated(who, value);
    }

    /// @notice Same as setWhitelisted, for several addresses in one transaction.
    function setWhitelistedBatch(address[] calldata whos, bool value) external onlyOwner {
        for (uint256 i = 0; i < whos.length; i++) {
            whitelisted[whos[i]] = value;
            emit WhitelistUpdated(whos[i], value);
        }
    }

    function setErevosShares(address _erevosShares) external onlyOwner {
        erevosShares = _erevosShares;
        emit ErevosSharesUpdated(_erevosShares);
    }

    function setErevosDiscountEnabled(bool enabled) external onlyOwner {
        erevosDiscountEnabled = enabled;
        emit ErevosDiscountEnabledUpdated(enabled);
    }

    function setMarketplace(address _marketplace) external onlyOwner {
        marketplace = _marketplace;
        emit MarketplaceUpdated(_marketplace);
    }

    function setNameWrapper(address _nameWrapper) external onlyOwner {
        nameWrapper = _nameWrapper;
        emit NameWrapperUpdated(_nameWrapper);
    }

    function setActivatedDomainDiscountEnabled(bool enabled) external onlyOwner {
        activatedDomainDiscountEnabled = enabled;
        emit ActivatedDomainDiscountEnabledUpdated(enabled);
    }
}
