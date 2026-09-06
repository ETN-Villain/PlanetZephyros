// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
/**
 * Planet Zephyros Premium
 *
 * A genuinely separate contract from PlanetZephyrosPnLStatement (contracts/premium/
 * PnlStatement.sol), not a V2/replacement of it — confirmed decision: PnL statement purchases
 * (purchasePnlPeriods/executeSplitForPeriod/refundPnlPeriod, and the whole discount-eligibility
 * machinery that only exists to price them) keep running on that contract, unchanged, because it
 * already works. This contract's only job is membership: subscribe() and subscribeAnnual(), moved
 * here specifically to fix a gap found live in the old contract — membership fees were collected
 * but never split (see that contract's own header: "Currently unlocks nothing on its own"). This
 * one splits the payment immediately, in the same transaction.
 *
 * Known consequence of splitting membership across two contracts (confirmed, not an oversight):
 * PlanetZephyrosPnLStatement's 50% PnL-statement discount for annual members
 * (isEligibleForDiscount -> isAnnualMember) reads THAT contract's own annualMembershipExpiry
 * mapping. Once subscribeAnnual() lives here instead, that mapping on the old contract stops
 * being written to — so an annual membership purchased through THIS contract does not grant the
 * PnL discount unless/until the old contract is separately updated to recognize it. Existing
 * annual members recorded on the old contract before this cutover are unaffected (their expiry is
 * already stored there); only annual subscriptions from this point forward are affected.
 *
 *  1) Membership, two independent tiers — same pricing/stacking rules as before:
 *     - subscribe() sells monthly membership (membershipExpiry). Gates Core Tier (see the
 *       dashboard's hasCoreAccess) and any further premium feature that wants to gate on
 *       isMembershipActive().
 *     - subscribeAnnual() sells annual-tier membership (annualMembershipExpiry) — tracked
 *       separately from monthly, same as on the old contract. Also counts toward hasCoreAccess.
 *
 *     Both now attempt to split the payment immediately, in the same transaction — half to
 *     splitDestination, half swapped ETN->CORE and burned, via _splitAndBurn below (the same
 *     swap-and-burn mechanics PlanetZephyrosPnLStatement.executeSplitForPeriod already uses). This
 *     is a deliberate best-effort attempt, not an all-or-nothing requirement: it runs through
 *     `try this._splitAndBurn(...)`, so if the swap leg fails for any reason (thin liquidity,
 *     slippage, router hiccup), the membership purchase itself still succeeds — the subscriber
 *     paid for a service (membership), not a swap, and a temporary DEX condition must never be
 *     able to block that. A failed attempt just leaves that ETN sitting in this contract's
 *     balance, ready for the operator to release later via executeMembershipSplit.
 *
 * Website: https://dashboard.planetzephyros.xyz/
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../subnames/interfaces/IUniswapV2Router02Lite.sol";
import "../subnames/interfaces/IBurnableERC20.sol";

contract PlanetZephyrosPremium is Ownable, ReentrancyGuard {
    // ========================
    // Roles
    // ========================
    /// @notice The dashboard backend's trusted wallet. Can only release already-escrowed
    /// (deferred-split) membership fees via executeMembershipSplit — cannot touch pricing, wiring
    /// addresses, or the pause switch. Deliberately a role separate from owner, same reasoning as
    /// PlanetZephyrosPnLStatement's operator.
    address public operator;

    // ========================
    // Membership pricing (two independent tiers)
    // ========================
    uint256 public constant SECONDS_PER_MONTH = 30 days;
    uint256 public constant SECONDS_PER_YEAR = 365 days;

    /// @notice Owner-adjustable ETN price per 30-day monthly membership period.
    uint256 public membershipPricePerMonth = 5_000 ether;

    /// @notice Owner-adjustable ETN price per 365-day annual membership period.
    uint256 public annualMembershipPricePerYear = 40_000 ether;

    /// @notice Monthly membership expiry (unix timestamp) per address. 0 / in the past = inactive.
    mapping(address => uint256) public membershipExpiry;

    /// @notice Annual membership expiry (unix timestamp) per address — tracked separately from
    /// membershipExpiry, same reasoning as the old contract (two structurally different
    /// commitments, not one "isMembershipActive" check).
    mapping(address => uint256) public annualMembershipExpiry;

    // ========================
    // Buy-and-burn wiring
    // ========================
    address public coreToken;
    address public swapRouter;

    /// @notice Receives the non-burn half of every executed split.
    address payable public splitDestination;

    uint256 public totalCoreBurned;

    bool public paused;

    // ========================
    // Events
    // ========================
    event MembershipPurchased(address indexed subscriber, uint256 numMonths, uint256 paid, uint256 newExpiry);
    event AnnualMembershipPurchased(address indexed subscriber, uint256 numYears, uint256 paid, uint256 newExpiry);
    /// @notice Emitted right after MembershipPurchased/AnnualMembershipPurchased when the
    /// immediate split succeeded.
    event MembershipFeeSplitExecuted(address indexed subscriber, uint256 amountSplit, address splitWallet, uint256 coreReceived, uint256 coreBurned);
    /// @notice Emitted instead of MembershipFeeSplitExecuted when the immediate split attempt
    /// failed (buyback not configured, or the swap leg reverted) — the membership purchase itself
    /// still succeeded (see contract header); `amount` is left in this contract's balance for the
    /// operator to release later via executeMembershipSplit.
    event MembershipFeeSplitDeferred(address indexed subscriber, uint256 amount, string reason);
    event MembershipSplitExecuted(address indexed operator, uint256 amountSplit, address splitWallet, uint256 coreReceived, uint256 coreBurned);
    event MembershipPricePerMonthUpdated(uint256 membershipPricePerMonth);
    event AnnualMembershipPricePerYearUpdated(uint256 annualMembershipPricePerYear);
    event CoreTokenUpdated(address coreToken);
    event SwapRouterUpdated(address swapRouter);
    event SplitDestinationUpdated(address splitDestination);
    event OperatorUpdated(address operator);
    event PausedUpdated(bool paused);

    // ========================
    // Modifiers
    // ========================
    modifier whenNotPaused() {
        require(!paused, "Premium paused");
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
    /// whichever is later of their current expiry or now, then attempts to immediately split the
    /// payment (see contract header — best-effort, never blocks the membership itself).
    /// minCoreOut/deadline size the swap leg of that split, quoted off-chain by the caller exactly
    /// like the dashboard backend already does for PlanetZephyrosPnLStatement's
    /// executeSplitForPeriod (see usePremiumSubscription.js).
    function subscribe(uint256 numMonths, uint256 minCoreOut, uint256 deadline) external payable whenNotPaused nonReentrant {
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
        _attemptImmediateSplit(required, minCoreOut, deadline);
    }

    /// @notice Extends msg.sender's ANNUAL membership by numYears 365-day periods — same
    /// stack-from-later-of-expiry-or-now / excess-refund / immediate-best-effort-split conventions
    /// as subscribe(). See contract header for the known cross-contract consequence for the PnL
    /// discount, which is checked entirely on the separate PlanetZephyrosPnLStatement contract.
    function subscribeAnnual(uint256 numYears, uint256 minCoreOut, uint256 deadline) external payable whenNotPaused nonReentrant {
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
        _attemptImmediateSplit(required, minCoreOut, deadline);
    }

    function isMembershipActive(address who) public view returns (bool) {
        return membershipExpiry[who] > block.timestamp;
    }

    function isAnnualMember(address who) public view returns (bool) {
        return annualMembershipExpiry[who] > block.timestamp;
    }

    /// @notice True if either tier is currently active — what the dashboard's Core Tier gates on
    /// (see backend/utils/premiumAccess.js's hasCoreAccess).
    function hasCoreAccess(address who) external view returns (bool) {
        return isMembershipActive(who) || isAnnualMember(who);
    }

    // ========================================================
    // Buy-and-burn core
    // ========================================================

    /// @notice Shared swap-and-burn logic: half of `amount` goes straight to splitDestination, the
    /// other half is swapped ETN->CORE and burned — copies PlanetZephyrosPnLStatement's
    /// executeSplitForPeriod unmodified. `external` + the self-call guard below (instead of
    /// `internal`) is deliberate: subscribe()/subscribeAnnual() call this through
    /// `try this._splitAndBurn(...)`, which only works across a real message call in Solidity — an
    /// internal call can't be try/catch'd. executeMembershipSplit below calls it the same way but
    /// does NOT catch the failure, since a stuck deferred split should revert so the operator's tx
    /// fails loudly and can simply be retried.
    function _splitAndBurn(uint256 amount, uint256 minCoreOut, uint256 deadline) external returns (uint256 received) {
        require(msg.sender == address(this), "Internal only");
        require(coreToken != address(0) && swapRouter != address(0), "Buyback not configured");
        require(amount > 0, "Nothing to split");

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

        received = IERC20(coreToken).balanceOf(address(this)) - balanceBefore;
        require(received > 0, "Swap failed");

        IBurnableERC20(coreToken).burn(received);
        totalCoreBurned += received;
    }

    /// @notice Best-effort immediate split for a just-collected membership fee — see contract
    /// header for why this must never revert the membership purchase itself. A caught failure
    /// (buyback unconfigured, swap reverted for any reason) leaves `amount` sitting in this
    /// contract's balance for the operator to release later via executeMembershipSplit.
    function _attemptImmediateSplit(uint256 amount, uint256 minCoreOut, uint256 deadline) internal {
        try this._splitAndBurn(amount, minCoreOut, deadline) returns (uint256 received) {
            emit MembershipFeeSplitExecuted(msg.sender, amount, splitDestination, received, received);
        } catch Error(string memory reason) {
            emit MembershipFeeSplitDeferred(msg.sender, amount, reason);
        } catch {
            emit MembershipFeeSplitDeferred(msg.sender, amount, "Unknown error");
        }
    }

    /// @notice Releases `amount` of this contract's escrowed balance (a deferred membership split
    /// — see MembershipFeeSplitDeferred — or, one time, whatever's rescued from the old contract):
    /// half to splitDestination, half swapped ETN->CORE and burned. Operator-only, same trust
    /// boundary as PlanetZephyrosPnLStatement's executeSplitForPeriod.
    function executeMembershipSplit(uint256 amount, uint256 minCoreOut, uint256 deadline) external onlyOperator whenNotPaused nonReentrant {
        require(address(this).balance >= amount, "Insufficient balance");
        uint256 received = this._splitAndBurn(amount, minCoreOut, deadline);
        emit MembershipSplitExecuted(msg.sender, amount, splitDestination, received, received);
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
}
