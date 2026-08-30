const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const ONE_MONTH = 30 * 24 * 60 * 60;
const ONE_YEAR = 365 * 24 * 60 * 60;
const NO_DOMAIN_CLAIM = ethers.ZeroHash; // bytes32(0) — "not claiming the activated-domain discount"

const PeriodType = { CalendarYear: 0, UKStyle: 1, AUStyle: 2, USStyle: 3 };

describe("PremiumSubscription", function () {
  async function deployFixture() {
    const [deployer, operator, splitWallet, alice, bob] = await ethers.getSigners();

    // Hardhat's default local-network balance (10,000 native units) is smaller than a handful of
    // pnlPricePerPeriod purchases (15,000 ETN each) once gas is added — top up the signers that
    // actually spend in these tests so the contract's real default prices can be exercised as-is.
    for (const signer of [alice, bob]) {
      await ethers.provider.send("hardhat_setBalance", [signer.address, "0x21E19E0C9BAB2400000000"]); // 10,000,000 ETH
    }

    const MockCoreToken = await ethers.getContractFactory("MockCoreToken");
    const core = await MockCoreToken.deploy();

    const wethDummy = ethers.Wallet.createRandom().address;
    const MockRouter = await ethers.getContractFactory("MockRouter");
    const router = await MockRouter.deploy(await core.getAddress(), wethDummy, 1000n);

    const MockErevosShares = await ethers.getContractFactory("MockErevosShares");
    const erevos = await MockErevosShares.deploy();

    const MockMarketplaceLite = await ethers.getContractFactory("MockMarketplaceLite");
    const marketplace = await MockMarketplaceLite.deploy();

    const MockNameWrapperLite = await ethers.getContractFactory("MockNameWrapperLite");
    const nameWrapper = await MockNameWrapperLite.deploy();

    const PremiumSubscription = await ethers.getContractFactory("PremiumSubscription");
    const premium = await PremiumSubscription.deploy(deployer.address, operator.address, splitWallet.address);

    return { deployer, operator, splitWallet, alice, bob, core, router, erevos, marketplace, nameWrapper, premium };
  }

  async function withBuybackConfigured() {
    const ctx = await deployFixture();
    const { premium, deployer, core, router } = ctx;
    await premium.connect(deployer).setCoreToken(await core.getAddress());
    await premium.connect(deployer).setSwapRouter(await router.getAddress());
    return ctx;
  }

  // A single already-ended calendar-year-2024 claim, for tests that don't care about period
  // shape/count specifics — just need one valid, already-elapsed period to pay for.
  async function pastPeriod(yearsAgo = 1) {
    const now = await time.latest();
    return { periodType: PeriodType.CalendarYear, year: 2024, periodEnd: now - yearsAgo * ONE_YEAR };
  }

  // Funds the contract's escrow via a real, non-discounted purchasePnlPeriods call — mirrors how
  // PlanetZephyrosSubdomainNameServiceV3's test suite fills burnPool through registerSubname
  // rather than sending ETN directly (this contract has no receive()/fallback).
  async function withEscrowedFunds() {
    const ctx = await withBuybackConfigured();
    const { premium, bob } = ctx;
    const price = await premium.pnlPricePerPeriod();
    await premium.connect(bob).purchasePnlPeriods(bob.address, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: price });
    return { ...ctx, escrowed: price };
  }

  describe("constructor", function () {
    it("reverts on zero operator", async function () {
      const [deployer, , splitWallet] = await ethers.getSigners();
      const PremiumSubscription = await ethers.getContractFactory("PremiumSubscription");
      await expect(
        PremiumSubscription.deploy(deployer.address, ethers.ZeroAddress, splitWallet.address)
      ).to.be.revertedWith("Zero operator");
    });

    it("reverts on zero split destination", async function () {
      const [deployer, operator] = await ethers.getSigners();
      const PremiumSubscription = await ethers.getContractFactory("PremiumSubscription");
      await expect(
        PremiumSubscription.deploy(deployer.address, operator.address, ethers.ZeroAddress)
      ).to.be.revertedWith("Zero split destination");
    });
  });

  describe("subscribe (monthly)", function () {
    it("reverts on numMonths = 0", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).subscribe(0, { value: 0 })).to.be.revertedWith(
        "numMonths must be >= 1"
      );
    });

    it("reverts on insufficient payment", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();
      await expect(
        premium.connect(alice).subscribe(1, { value: price - 1n })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("grants exactly numMonths from now on a fresh subscription and refunds excess", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();

      const before = await ethers.provider.getBalance(alice.address);
      const tx = await premium.connect(alice).subscribe(2, { value: price * 2n + ethers.parseEther("1") });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(alice.address);

      expect(before - after).to.equal(price * 2n + gasCost);

      const expiry = await premium.membershipExpiry(alice.address);
      const nowTs = BigInt(await time.latest());
      expect(expiry).to.be.closeTo(nowTs + BigInt(2 * ONE_MONTH), 5n);
      expect(await premium.isMembershipActive(alice.address)).to.equal(true);
    });

    it("does NOT make the caller eligible for the PnL discount", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();
      await premium.connect(alice).subscribe(12, { value: price * 12n }); // a full year of monthly, still not annual tier

      expect(await premium.isMembershipActive(alice.address)).to.equal(true);
      expect(await premium.isAnnualMember(alice.address)).to.equal(false);
      expect(await premium.isEligibleForDiscount(alice.address)).to.equal(false);
    });

    it("emits MembershipPurchased", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();
      await expect(premium.connect(alice).subscribe(1, { value: price })).to.emit(
        premium,
        "MembershipPurchased"
      );
    });

    it("reverts when paused", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();
      await premium.connect(deployer).setPaused(true);
      await expect(premium.connect(alice).subscribe(1, { value: price })).to.be.revertedWith(
        "Premium subscription paused"
      );
    });
  });

  describe("subscribeAnnual", function () {
    it("reverts on numYears = 0", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).subscribeAnnual(0, { value: 0 })).to.be.revertedWith(
        "numYears must be >= 1"
      );
    });

    it("reverts on insufficient payment", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();
      await expect(
        premium.connect(alice).subscribeAnnual(1, { value: price - 1n })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("grants exactly numYears from now and refunds excess", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();

      const before = await ethers.provider.getBalance(alice.address);
      const tx = await premium.connect(alice).subscribeAnnual(2, { value: price * 2n + ethers.parseEther("1") });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(alice.address);

      expect(before - after).to.equal(price * 2n + gasCost);

      const expiry = await premium.annualMembershipExpiry(alice.address);
      const nowTs = BigInt(await time.latest());
      expect(expiry).to.be.closeTo(nowTs + BigInt(2 * ONE_YEAR), 5n);
      expect(await premium.isAnnualMember(alice.address)).to.equal(true);
    });

    it("stacks additional years onto an existing, still-active annual membership", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();

      await premium.connect(alice).subscribeAnnual(1, { value: price });
      const firstExpiry = await premium.annualMembershipExpiry(alice.address);

      await premium.connect(alice).subscribeAnnual(1, { value: price });
      const secondExpiry = await premium.annualMembershipExpiry(alice.address);

      expect(secondExpiry).to.equal(firstExpiry + BigInt(ONE_YEAR));
    });

    it("makes the caller eligible for the PnL discount", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();
      await premium.connect(alice).subscribeAnnual(1, { value: price });

      expect(await premium.isEligibleForDiscount(alice.address)).to.equal(true);
    });

    it("emits AnnualMembershipPurchased", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();
      await expect(premium.connect(alice).subscribeAnnual(1, { value: price })).to.emit(
        premium,
        "AnnualMembershipPurchased"
      );
    });

    it("reverts when paused", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      const price = await premium.annualMembershipPricePerYear();
      await premium.connect(deployer).setPaused(true);
      await expect(premium.connect(alice).subscribeAnnual(1, { value: price })).to.be.revertedWith(
        "Premium subscription paused"
      );
    });
  });

  describe("purchasePnlPeriods", function () {
    it("reverts on zero tracked wallet", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).purchasePnlPeriods(ethers.ZeroAddress, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Zero tracked wallet");
    });

    it("reverts on an empty periods array", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [], NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Must purchase at least one period");
    });

    it("reverts on more than MAX_PERIODS_PER_PURCHASE periods", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const max = await premium.MAX_PERIODS_PER_PURCHASE();
      const claim = await pastPeriod();
      const tooMany = Array.from({ length: Number(max) + 1 }, () => claim);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, tooMany, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Too many periods in one purchase");
    });

    it("reverts if a period's end has not yet passed", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const now = await time.latest();
      const futureClaim = { periodType: PeriodType.CalendarYear, year: 2099, periodEnd: now + ONE_YEAR };
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [futureClaim], NO_DOMAIN_CLAIM, { value: await premium.pnlPricePerPeriod() })
      ).to.be.revertedWith("Period has not ended yet");
    });

    it("charges full price for a single period and refunds excess", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.pnlPricePerPeriod();
      const claim = await pastPeriod();

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [claim], NO_DOMAIN_CLAIM, { value: price - 1n })
      ).to.be.revertedWith("Insufficient payment");

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [claim], NO_DOMAIN_CLAIM, { value: price + ethers.parseEther("1") })
      )
        .to.emit(premium, "PnlPeriodPurchased")
        .withArgs(alice.address, alice.address, claim.periodType, claim.year, claim.periodEnd, price);
    });

    it("multi-buy pricing: first period full price, every subsequent period 2/3 price (33% off), when not otherwise discounted", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.pnlPricePerPeriod(); // 15,000 ETN
      const multiBuyPrice = (price * 2n) / 3n; // 10,000 ETN

      const claims = [await pastPeriod(3), await pastPeriod(2), await pastPeriod(1)];
      const total = price + multiBuyPrice + multiBuyPrice; // 15k + 10k + 10k = 35k

      expect(ethers.formatEther(price)).to.equal("15000.0");
      expect(ethers.formatEther(multiBuyPrice)).to.equal("10000.0");
      expect(ethers.formatEther(total)).to.equal("35000.0");

      const tx = await premium.connect(alice).purchasePnlPeriods(alice.address, claims, NO_DOMAIN_CLAIM, { value: total });
      const receipt = await tx.wait();
      const parsed = receipt.logs.map((l) => { try { return premium.interface.parseLog(l); } catch { return null; } }).filter((e) => e && e.name === "PnlPeriodPurchased");

      expect(parsed.length).to.equal(3);
      expect(parsed[0].args.amountPaid).to.equal(price);
      expect(parsed[1].args.amountPaid).to.equal(multiBuyPrice);
      expect(parsed[2].args.amountPaid).to.equal(multiBuyPrice);
    });

    it("discount-eligible caller pays the flat 50% price for every period, with no multi-buy stacking", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const annualPrice = await premium.annualMembershipPricePerYear();
      await premium.connect(alice).subscribeAnnual(1, { value: annualPrice });

      const price = await premium.pnlPricePerPeriod();
      const discountedPrice = price / 2n; // 7,500 ETN

      const claims = [await pastPeriod(3), await pastPeriod(2), await pastPeriod(1)];
      const total = discountedPrice * 3n; // NOT price + 2*multiBuyPrice — no stacking

      const tx = await premium.connect(alice).purchasePnlPeriods(alice.address, claims, NO_DOMAIN_CLAIM, { value: total });
      const receipt = await tx.wait();
      const parsed = receipt.logs.map((l) => { try { return premium.interface.parseLog(l); } catch { return null; } }).filter((e) => e && e.name === "PnlPeriodPurchased");

      expect(parsed.length).to.equal(3);
      for (const event of parsed) {
        expect(event.args.amountPaid).to.equal(discountedPrice);
      }
    });

    it("whitelisted caller gets the 50% discount", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setWhitelisted(alice.address, true);
      const discountedPrice = (await premium.pnlPricePerPeriod()) / 2n;

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: discountedPrice })
      ).to.emit(premium, "PnlPeriodPurchased");
    });

    it("ErevosShares holder gets the 50% discount only while erevosDiscountEnabled is true", async function () {
      const { premium, deployer, erevos, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setErevosShares(await erevos.getAddress());
      await erevos.mint(alice.address);
      const price = await premium.pnlPricePerPeriod();
      const discountedPrice = price / 2n;

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: discountedPrice })
      ).to.emit(premium, "PnlPeriodPurchased");

      await premium.connect(deployer).setErevosDiscountEnabled(false);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod(4)], NO_DOMAIN_CLAIM, { value: discountedPrice })
      ).to.be.revertedWith("Insufficient payment"); // now needs full price since the path is disabled
    });

    it("activated-domain owner gets the 50% discount only while activatedDomainDiscountEnabled is true", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());
      const node = ethers.id("alice.etn");
      await marketplace.setActivated(node, true);
      await nameWrapper.setOwner(BigInt(node), alice.address);

      const price = await premium.pnlPricePerPeriod();
      const discountedPrice = price / 2n;

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], node, { value: discountedPrice })
      ).to.emit(premium, "PnlPeriodPurchased");

      await premium.connect(deployer).setActivatedDomainDiscountEnabled(false);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod(4)], node, { value: discountedPrice })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("does not grant the discount for a node that isn't activated, or one the caller doesn't own", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice, bob } = await loadFixture(deployFixture);
      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());
      const discountedPrice = (await premium.pnlPricePerPeriod()) / 2n;

      const notActivated = ethers.id("not-activated.etn");
      await nameWrapper.setOwner(BigInt(notActivated), alice.address);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], notActivated, { value: discountedPrice })
      ).to.be.revertedWith("Insufficient payment");

      const ownedByBob = ethers.id("bob.etn");
      await marketplace.setActivated(ownedByBob, true);
      await nameWrapper.setOwner(BigInt(ownedByBob), bob.address);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], ownedByBob, { value: discountedPrice })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("reverts when paused", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setPaused(true);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: await premium.pnlPricePerPeriod() })
      ).to.be.revertedWith("Premium subscription paused");
    });
  });

  describe("executeSplitForPeriod", function () {
    it("reverts if caller is not operator", async function () {
      const { premium, deployer } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(deployer).executeSplitForPeriod(1n, 0, (await time.latest()) + 300)
      ).to.be.revertedWith("Not operator");
    });

    it("reverts if buyback is not configured", async function () {
      const { premium, operator, bob } = await loadFixture(deployFixture);
      await premium.connect(bob).purchasePnlPeriods(bob.address, [await pastPeriod()], NO_DOMAIN_CLAIM, { value: await premium.pnlPricePerPeriod() });
      await expect(
        premium.connect(operator).executeSplitForPeriod(1n, 0, (await time.latest()) + 300)
      ).to.be.revertedWith("Buyback not configured");
    });

    it("reverts on amount = 0", async function () {
      const { premium, operator } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(operator).executeSplitForPeriod(0, 0, (await time.latest()) + 300)
      ).to.be.revertedWith("Nothing to split");
    });

    it("reverts if amount exceeds the contract's balance", async function () {
      const { premium, operator, escrowed } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(operator).executeSplitForPeriod(escrowed + 1n, 0, (await time.latest()) + 300)
      ).to.be.revertedWith("Insufficient balance");
    });

    it("splits half to splitDestination and swaps+burns the other half", async function () {
      const { premium, operator, splitWallet, core, router, escrowed } = await loadFixture(withEscrowedFunds);
      const rate = await router.rate();
      const toSplitWallet = escrowed / 2n;
      const toSwap = escrowed - toSplitWallet;
      const expectedCoreBurned = toSwap * rate;

      const splitWalletBefore = await ethers.provider.getBalance(splitWallet.address);

      await expect(
        premium.connect(operator).executeSplitForPeriod(escrowed, 0, (await time.latest()) + 300)
      )
        .to.emit(premium, "PnlPeriodSplitExecuted")
        .withArgs(operator.address, escrowed, splitWallet.address, expectedCoreBurned, expectedCoreBurned);

      expect(await ethers.provider.getBalance(splitWallet.address)).to.equal(splitWalletBefore + toSplitWallet);
      expect(await premium.totalCoreBurned()).to.equal(expectedCoreBurned);
      expect(await core.totalSupply()).to.equal(0); // minted then burned within the same tx
    });

    it("reverts on slippage when minCoreOut cannot be met", async function () {
      const { premium, operator, router, escrowed } = await loadFixture(withEscrowedFunds);
      const rate = await router.rate();
      const toSwap = escrowed - escrowed / 2n;

      await expect(
        premium.connect(operator).executeSplitForPeriod(escrowed, toSwap * rate + 1n, (await time.latest()) + 300)
      ).to.be.revertedWith("Insufficient output amount");
    });

    it("reverts when paused", async function () {
      const { premium, deployer, operator, escrowed } = await loadFixture(withEscrowedFunds);
      await premium.connect(deployer).setPaused(true);
      await expect(
        premium.connect(operator).executeSplitForPeriod(escrowed, 0, (await time.latest()) + 300)
      ).to.be.revertedWith("Premium subscription paused");
    });
  });

  describe("refundPnlPeriod", function () {
    it("reverts if caller is not operator", async function () {
      const { premium, deployer, alice, escrowed } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(deployer).refundPnlPeriod(alice.address, escrowed)
      ).to.be.revertedWith("Not operator");
    });

    it("reverts on zero destination", async function () {
      const { premium, operator, escrowed } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(operator).refundPnlPeriod(ethers.ZeroAddress, escrowed)
      ).to.be.revertedWith("Zero refund destination");
    });

    it("reverts on amount = 0", async function () {
      const { premium, operator, alice } = await loadFixture(withEscrowedFunds);
      await expect(premium.connect(operator).refundPnlPeriod(alice.address, 0)).to.be.revertedWith(
        "Nothing to refund"
      );
    });

    it("reverts if amount exceeds the contract's balance", async function () {
      const { premium, operator, alice, escrowed } = await loadFixture(withEscrowedFunds);
      await expect(
        premium.connect(operator).refundPnlPeriod(alice.address, escrowed + 1n)
      ).to.be.revertedWith("Insufficient balance");
    });

    it("transfers the amount to the destination and emits PnlPeriodRefunded", async function () {
      const { premium, operator, alice, escrowed } = await loadFixture(withEscrowedFunds);
      const before = await ethers.provider.getBalance(alice.address);

      await expect(premium.connect(operator).refundPnlPeriod(alice.address, escrowed))
        .to.emit(premium, "PnlPeriodRefunded")
        .withArgs(operator.address, alice.address, escrowed);

      expect(await ethers.provider.getBalance(alice.address)).to.equal(before + escrowed);
    });

    it("reverts when paused", async function () {
      const { premium, deployer, operator, alice, escrowed } = await loadFixture(withEscrowedFunds);
      await premium.connect(deployer).setPaused(true);
      await expect(
        premium.connect(operator).refundPnlPeriod(alice.address, escrowed)
      ).to.be.revertedWith("Premium subscription paused");
    });
  });

  describe("admin", function () {
    it("setMembershipPricePerMonth: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setMembershipPricePerMonth(1n)
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      await expect(premium.connect(deployer).setMembershipPricePerMonth(123n))
        .to.emit(premium, "MembershipPricePerMonthUpdated")
        .withArgs(123n);
      expect(await premium.membershipPricePerMonth()).to.equal(123n);
    });

    it("setAnnualMembershipPricePerYear: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setAnnualMembershipPricePerYear(1n)
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      await expect(premium.connect(deployer).setAnnualMembershipPricePerYear(789n))
        .to.emit(premium, "AnnualMembershipPricePerYearUpdated")
        .withArgs(789n);
      expect(await premium.annualMembershipPricePerYear()).to.equal(789n);
    });

    it("setPnlPricePerPeriod: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).setPnlPricePerPeriod(1n)).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );

      await expect(premium.connect(deployer).setPnlPricePerPeriod(456n))
        .to.emit(premium, "PnlPricePerPeriodUpdated")
        .withArgs(456n);
      expect(await premium.pnlPricePerPeriod()).to.equal(456n);
    });

    it("setCoreToken / setSwapRouter: owner-only, update values, emit events", async function () {
      const { premium, deployer, alice, core, router } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).setCoreToken(await core.getAddress())).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );

      await expect(premium.connect(deployer).setCoreToken(await core.getAddress()))
        .to.emit(premium, "CoreTokenUpdated")
        .withArgs(await core.getAddress());
      await expect(premium.connect(deployer).setSwapRouter(await router.getAddress()))
        .to.emit(premium, "SwapRouterUpdated")
        .withArgs(await router.getAddress());

      expect(await premium.coreToken()).to.equal(await core.getAddress());
      expect(await premium.swapRouter()).to.equal(await router.getAddress());
    });

    it("setSplitDestination: owner-only, rejects zero address, updates value, emits event", async function () {
      const { premium, deployer, alice, bob } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setSplitDestination(bob.address)
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");
      await expect(
        premium.connect(deployer).setSplitDestination(ethers.ZeroAddress)
      ).to.be.revertedWith("Zero split destination");

      await expect(premium.connect(deployer).setSplitDestination(bob.address))
        .to.emit(premium, "SplitDestinationUpdated")
        .withArgs(bob.address);
      expect(await premium.splitDestination()).to.equal(bob.address);
    });

    it("setOperator: owner-only, rejects zero address, updates value, emits event", async function () {
      const { premium, deployer, alice, bob } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).setOperator(bob.address)).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );
      await expect(premium.connect(deployer).setOperator(ethers.ZeroAddress)).to.be.revertedWith(
        "Zero operator"
      );

      await expect(premium.connect(deployer).setOperator(bob.address))
        .to.emit(premium, "OperatorUpdated")
        .withArgs(bob.address);
      expect(await premium.operator()).to.equal(bob.address);
    });

    it("setPaused: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).setPaused(true)).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );

      await expect(premium.connect(deployer).setPaused(true))
        .to.emit(premium, "PausedUpdated")
        .withArgs(true);
      expect(await premium.paused()).to.equal(true);
    });

    it("setWhitelisted: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await expect(premium.connect(alice).setWhitelisted(alice.address, true)).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );

      await expect(premium.connect(deployer).setWhitelisted(alice.address, true))
        .to.emit(premium, "WhitelistUpdated")
        .withArgs(alice.address, true);
      expect(await premium.whitelisted(alice.address)).to.equal(true);
    });

    it("setWhitelistedBatch: owner-only, emits one event per address", async function () {
      const { premium, deployer, alice, bob } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setWhitelistedBatch([alice.address], true)
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      const tx = await premium.connect(deployer).setWhitelistedBatch([alice.address, bob.address], true);
      await expect(tx).to.emit(premium, "WhitelistUpdated").withArgs(alice.address, true);
      await expect(tx).to.emit(premium, "WhitelistUpdated").withArgs(bob.address, true);
    });

    it("setErevosShares / setErevosDiscountEnabled: owner-only, update values, emit events", async function () {
      const { premium, deployer, alice, erevos } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setErevosShares(await erevos.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");
      await expect(premium.connect(alice).setErevosDiscountEnabled(false)).to.be.revertedWithCustomError(
        premium,
        "OwnableUnauthorizedAccount"
      );

      await expect(premium.connect(deployer).setErevosShares(await erevos.getAddress()))
        .to.emit(premium, "ErevosSharesUpdated")
        .withArgs(await erevos.getAddress());
      expect(await premium.erevosShares()).to.equal(await erevos.getAddress());

      expect(await premium.erevosDiscountEnabled()).to.equal(true); // default on
      await expect(premium.connect(deployer).setErevosDiscountEnabled(false))
        .to.emit(premium, "ErevosDiscountEnabledUpdated")
        .withArgs(false);
      expect(await premium.erevosDiscountEnabled()).to.equal(false);
    });

    it("setMarketplace / setNameWrapper / setActivatedDomainDiscountEnabled: owner-only, update values, emit events", async function () {
      const { premium, deployer, alice, marketplace, nameWrapper } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setMarketplace(await marketplace.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");
      await expect(
        premium.connect(alice).setNameWrapper(await nameWrapper.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");
      await expect(
        premium.connect(alice).setActivatedDomainDiscountEnabled(false)
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      await expect(premium.connect(deployer).setMarketplace(await marketplace.getAddress()))
        .to.emit(premium, "MarketplaceUpdated")
        .withArgs(await marketplace.getAddress());
      await expect(premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress()))
        .to.emit(premium, "NameWrapperUpdated")
        .withArgs(await nameWrapper.getAddress());

      expect(await premium.marketplace()).to.equal(await marketplace.getAddress());
      expect(await premium.nameWrapper()).to.equal(await nameWrapper.getAddress());

      expect(await premium.activatedDomainDiscountEnabled()).to.equal(true); // default on
      await expect(premium.connect(deployer).setActivatedDomainDiscountEnabled(false))
        .to.emit(premium, "ActivatedDomainDiscountEnabledUpdated")
        .withArgs(false);
      expect(await premium.activatedDomainDiscountEnabled()).to.equal(false);
    });
  });
});
