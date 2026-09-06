const { expect } = require("chai");
const { ethers } = require("hardhat");

const ONE_MONTH = 30 * 24 * 60 * 60;
const ONE_YEAR = 365 * 24 * 60 * 60;

describe("PlanetZephyrosPremium", function () {
  async function deployFixture() {
    const [deployer, operator, splitWallet, alice] = await ethers.getSigners();

    // Hardhat's default local-network balance (10,000 native units) is smaller than the annual
    // tier's default price (40,000 ETN) plus gas across several tests reusing the same signer —
    // same top-up PremiumSubscription.test.js's own fixture already does.
    await ethers.provider.send("hardhat_setBalance", [alice.address, "0x21E19E0C9BAB2400000000"]); // 10,000,000 ETH

    const MockCoreToken = await ethers.getContractFactory("MockCoreToken");
    const core = await MockCoreToken.deploy();

    const wethDummy = ethers.Wallet.createRandom().address;
    const MockRouter = await ethers.getContractFactory("MockRouter");
    const router = await MockRouter.deploy(await core.getAddress(), wethDummy, 1000n);

    const Premium = await ethers.getContractFactory("PlanetZephyrosPremium");
    const premium = await Premium.deploy(deployer.address, operator.address, splitWallet.address);

    return { deployer, operator, splitWallet, alice, core, router, premium };
  }

  async function withBuybackConfigured() {
    const ctx = await deployFixture();
    const { premium, deployer, core, router } = ctx;
    await premium.connect(deployer).setCoreToken(await core.getAddress());
    await premium.connect(deployer).setSwapRouter(await router.getAddress());
    return ctx;
  }

  describe("subscribe (monthly)", function () {
    it("sets membershipExpiry, refunds excess, and immediately splits+burns when buyback is configured", async function () {
      const { premium, alice, splitWallet, core } = await withBuybackConfigured();
      const price = await premium.membershipPricePerMonth();

      const overpay = price + ethers.parseEther("10");
      const splitBalanceBefore = await ethers.provider.getBalance(splitWallet.address);

      await expect(premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: overpay }))
        .to.emit(premium, "MembershipPurchased")
        .and.to.emit(premium, "MembershipFeeSplitExecuted");

      expect(await premium.isMembershipActive(alice.address)).to.equal(true);

      // Excess refunded — contract holds neither the overpayment nor (since the split succeeded)
      // the base price itself.
      expect(await ethers.provider.getBalance(await premium.getAddress())).to.equal(0n);

      // Half went to splitWallet, half was swapped to CORE and burned (MockCoreToken.burn reduces
      // total supply, so a nonzero totalCoreBurned plus a zero CORE balance on the contract is the
      // right signal that burn(), not just mint(), actually ran).
      expect(await ethers.provider.getBalance(splitWallet.address)).to.equal(splitBalanceBefore + price / 2n);
      expect(await premium.totalCoreBurned()).to.be.gt(0n);
      expect(await core.balanceOf(await premium.getAddress())).to.equal(0n);
    });

    it("extends from the current expiry, not from now, on a repeat purchase", async function () {
      const { premium, alice } = await withBuybackConfigured();
      const price = await premium.membershipPricePerMonth();

      await premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: price });
      const firstExpiry = await premium.membershipExpiry(alice.address);

      await premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: price });
      const secondExpiry = await premium.membershipExpiry(alice.address);

      expect(secondExpiry).to.equal(firstExpiry + BigInt(ONE_MONTH));
    });

    it("succeeds even when the swap leg reverts (bad minCoreOut) — membership grants, fee stays escrowed", async function () {
      const { premium, alice } = await withBuybackConfigured();
      const price = await premium.membershipPricePerMonth();

      // An impossibly high minCoreOut guarantees the router's own slippage check reverts.
      await expect(premium.connect(alice).subscribe(1, ethers.MaxUint256, ethers.MaxUint256, { value: price }))
        .to.emit(premium, "MembershipPurchased")
        .and.to.emit(premium, "MembershipFeeSplitDeferred");

      expect(await premium.isMembershipActive(alice.address)).to.equal(true);
      // The whole fee is still sitting in the contract, available for a later operator sweep.
      expect(await ethers.provider.getBalance(await premium.getAddress())).to.equal(price);
    });

    it("succeeds when buyback isn't configured at all", async function () {
      const { premium, alice } = await deployFixture(); // no setCoreToken/setSwapRouter
      const price = await premium.membershipPricePerMonth();

      await expect(premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: price }))
        .to.emit(premium, "MembershipPurchased")
        .and.to.emit(premium, "MembershipFeeSplitDeferred");

      expect(await premium.isMembershipActive(alice.address)).to.equal(true);
    });

    it("rejects insufficient payment", async function () {
      const { premium, alice } = await deployFixture();
      const price = await premium.membershipPricePerMonth();
      await expect(
        premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: price - 1n })
      ).to.be.revertedWith("Insufficient payment");
    });
  });

  describe("subscribeAnnual", function () {
    it("sets annualMembershipExpiry independently of the monthly tier", async function () {
      const { premium, alice } = await withBuybackConfigured();
      const price = await premium.annualMembershipPricePerYear();

      await premium.connect(alice).subscribeAnnual(1, 0, ethers.MaxUint256, { value: price });

      expect(await premium.isAnnualMember(alice.address)).to.equal(true);
      expect(await premium.isMembershipActive(alice.address)).to.equal(false);

      const expiry = await premium.annualMembershipExpiry(alice.address);
      const latest = BigInt((await ethers.provider.getBlock("latest")).timestamp);
      expect(expiry).to.be.closeTo(latest + BigInt(ONE_YEAR), 5n);
    });
  });

  describe("hasCoreAccess", function () {
    it("is true for either tier and false for neither", async function () {
      const { premium, alice } = await withBuybackConfigured();
      expect(await premium.hasCoreAccess(alice.address)).to.equal(false);

      await premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: await premium.membershipPricePerMonth() });
      expect(await premium.hasCoreAccess(alice.address)).to.equal(true);
    });
  });

  describe("executeMembershipSplit (operator rescue path)", function () {
    it("releases a deferred fee when called by the operator", async function () {
      const { premium, operator, alice, splitWallet } = await deployFixture(); // buyback not configured -> deferred
      const price = await premium.membershipPricePerMonth();
      await premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: price });
      expect(await ethers.provider.getBalance(await premium.getAddress())).to.equal(price);

      // Wire up buyback now, then let the operator sweep the previously-deferred fee.
      const MockCoreToken = await ethers.getContractFactory("MockCoreToken");
      const core = await MockCoreToken.deploy();
      const MockRouter = await ethers.getContractFactory("MockRouter");
      const router = await MockRouter.deploy(await core.getAddress(), ethers.Wallet.createRandom().address, 1000n);
      const [deployer] = await ethers.getSigners();
      await premium.connect(deployer).setCoreToken(await core.getAddress());
      await premium.connect(deployer).setSwapRouter(await router.getAddress());

      const splitBalanceBefore = await ethers.provider.getBalance(splitWallet.address);
      await expect(premium.connect(operator).executeMembershipSplit(price, 0, ethers.MaxUint256))
        .to.emit(premium, "MembershipSplitExecuted");

      expect(await ethers.provider.getBalance(await premium.getAddress())).to.equal(0n);
      expect(await ethers.provider.getBalance(splitWallet.address)).to.equal(splitBalanceBefore + price / 2n);
    });

    it("rejects a non-operator caller", async function () {
      const { premium, alice } = await withBuybackConfigured();
      await expect(
        premium.connect(alice).executeMembershipSplit(1, 0, ethers.MaxUint256)
      ).to.be.revertedWith("Not operator");
    });
  });

  describe("admin", function () {
    it("rejects non-owner calls to setters", async function () {
      const { premium, alice } = await deployFixture();
      await expect(premium.connect(alice).setMembershipPricePerMonth(1)).to.be.reverted;
      await expect(premium.connect(alice).setOperator(alice.address)).to.be.reverted;
    });

    it("blocks subscribe while paused", async function () {
      const { premium, deployer, alice } = await deployFixture();
      await premium.connect(deployer).setPaused(true);
      await expect(
        premium.connect(alice).subscribe(1, 0, ethers.MaxUint256, { value: await premium.membershipPricePerMonth() })
      ).to.be.revertedWith("Premium paused");
    });
  });
});
