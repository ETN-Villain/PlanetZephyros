const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const ONE_MONTH = 30 * 24 * 60 * 60;
const NO_DOMAIN_CLAIM = ethers.ZeroHash; // bytes32(0) — "not claiming free access via an activated domain"

describe("PremiumSubscription", function () {
  async function deployFixture() {
    const [deployer, operator, splitWallet, alice, bob] = await ethers.getSigners();

    // Hardhat's default local-network balance (10,000 native units) is smaller than a single
    // pnlPricePerPeriod (10,000 ETN) once gas is added, let alone a multi-period purchase — top
    // up the signers that actually spend in these tests so the contract's real default prices
    // (5,000/10,000 ETN) can be exercised as-is rather than testing against artificially small
    // stand-in values.
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

  // Funds the contract's escrow via a real, non-member purchasePnlPeriods call — mirrors how
  // PlanetZephyrosSubdomainNameServiceV3's test suite fills burnPool through registerSubname
  // rather than sending ETN directly (this contract has no receive()/fallback).
  async function withEscrowedFunds() {
    const ctx = await withBuybackConfigured();
    const { premium, bob } = ctx;
    const price = await premium.pnlPricePerPeriod();
    await premium.connect(bob).purchasePnlPeriods(bob.address, 1, NO_DOMAIN_CLAIM, { value: price });
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

  describe("subscribe", function () {
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

      // Only the exact required amount (price * 2) plus gas left alice's balance — the 1 ETN
      // overpayment came back.
      expect(before - after).to.equal(price * 2n + gasCost);

      const expiry = await premium.membershipExpiry(alice.address);
      const nowTs = BigInt(await time.latest());
      expect(expiry).to.be.closeTo(nowTs + BigInt(2 * ONE_MONTH), 5n);
      expect(await premium.isMembershipActive(alice.address)).to.equal(true);
    });

    it("stacks additional months onto an existing, still-active membership rather than resetting it", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.membershipPricePerMonth();

      await premium.connect(alice).subscribe(1, { value: price });
      const firstExpiry = await premium.membershipExpiry(alice.address);

      await premium.connect(alice).subscribe(1, { value: price });
      const secondExpiry = await premium.membershipExpiry(alice.address);

      expect(secondExpiry).to.equal(firstExpiry + BigInt(ONE_MONTH));
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

  describe("purchasePnlPeriods", function () {
    it("reverts on zero tracked wallet", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).purchasePnlPeriods(ethers.ZeroAddress, 1, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Zero tracked wallet");
    });

    it("reverts on numPeriods = 0", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 0, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("numPeriods must be >= 1");
    });

    it("charges a non-member the full price for every period and refunds excess", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const price = await premium.pnlPricePerPeriod();

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 3, NO_DOMAIN_CLAIM, { value: price * 3n - 1n })
      ).to.be.revertedWith("Insufficient payment");

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 3, NO_DOMAIN_CLAIM, { value: price * 3n + ethers.parseEther("1") })
      )
        .to.emit(premium, "PnlPeriodsPurchased")
        .withArgs(alice.address, alice.address, 3, price * 3n);
    });

    it("charges an active member nothing, even for multiple periods", async function () {
      const { premium, alice, bob } = await loadFixture(deployFixture);
      const membershipPrice = await premium.membershipPricePerMonth();
      await premium.connect(alice).subscribe(1, { value: membershipPrice });

      await expect(premium.connect(alice).purchasePnlPeriods(bob.address, 5, NO_DOMAIN_CLAIM, { value: 0 }))
        .to.emit(premium, "PnlPeriodsPurchased")
        .withArgs(alice.address, bob.address, 5, 0);
    });

    it("refunds the full amount if an active member overpays anyway", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const membershipPrice = await premium.membershipPricePerMonth();
      await premium.connect(alice).subscribe(1, { value: membershipPrice });

      const before = await ethers.provider.getBalance(alice.address);
      const tx = await premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: ethers.parseEther("1") });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const after = await ethers.provider.getBalance(alice.address);

      expect(before - after).to.equal(gasCost); // the whole 1 ETN came back
    });

    it("charges a whitelisted caller nothing", async function () {
      const { premium, deployer, alice, bob } = await loadFixture(deployFixture);
      await premium.connect(deployer).setWhitelisted(alice.address, true);

      await expect(premium.connect(alice).purchasePnlPeriods(bob.address, 2, NO_DOMAIN_CLAIM, { value: 0 }))
        .to.emit(premium, "PnlPeriodsPurchased")
        .withArgs(alice.address, bob.address, 2, 0);
    });

    it("setWhitelistedBatch whitelists every address in one call", async function () {
      const { premium, deployer, alice, bob } = await loadFixture(deployFixture);
      await premium.connect(deployer).setWhitelistedBatch([alice.address, bob.address], true);

      expect(await premium.whitelisted(alice.address)).to.equal(true);
      expect(await premium.whitelisted(bob.address)).to.equal(true);
    });

    it("un-whitelisting via setWhitelisted(false) makes the caller pay again", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      const price = await premium.pnlPricePerPeriod();
      await premium.connect(deployer).setWhitelisted(alice.address, true);
      await premium.connect(deployer).setWhitelisted(alice.address, false);

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Insufficient payment");
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: price })
      ).to.emit(premium, "PnlPeriodsPurchased");
    });

    it("charges an ErevosShares holder nothing, but not a non-holder", async function () {
      const { premium, deployer, erevos, alice, bob } = await loadFixture(deployFixture);
      await premium.connect(deployer).setErevosShares(await erevos.getAddress());
      await erevos.mint(alice.address);

      await expect(premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: 0 }))
        .to.emit(premium, "PnlPeriodsPurchased")
        .withArgs(alice.address, alice.address, 1, 0);

      // bob holds no shares — still has to pay.
      await expect(
        premium.connect(bob).purchasePnlPeriods(bob.address, 1, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("erevosShares unset (address(0)) disables that free path entirely", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      // Never configured — isEligibleForFreeAccess must not revert or treat this as free.
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: 0 })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("charges nothing when the caller proves ownership of an activated domain", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());

      const node = ethers.id("alice.etn");
      await marketplace.setActivated(node, true);
      await nameWrapper.setOwner(BigInt(node), alice.address);

      await expect(premium.connect(alice).purchasePnlPeriods(alice.address, 1, node, { value: 0 }))
        .to.emit(premium, "PnlPeriodsPurchased")
        .withArgs(alice.address, alice.address, 1, 0);
    });

    it("does not grant free access for a node that isn't activated", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());

      const node = ethers.id("alice.etn");
      // Owned by alice, but never marked activated on the marketplace.
      await nameWrapper.setOwner(BigInt(node), alice.address);

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, node, { value: 0 })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("does not grant free access for an activated node the caller doesn't own", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice, bob } = await loadFixture(deployFixture);
      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());

      const node = ethers.id("bob.etn");
      await marketplace.setActivated(node, true);
      await nameWrapper.setOwner(BigInt(node), bob.address); // owned by bob, not alice

      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, node, { value: 0 })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("marketplace/nameWrapper unset disables the activated-domain free path without reverting", async function () {
      const { premium, alice } = await loadFixture(deployFixture);
      const node = ethers.id("alice.etn");
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, node, { value: 0 })
      ).to.be.revertedWith("Insufficient payment"); // falls through to the paid path, never reverts on the bogus claim itself
    });

    it("isEligibleForFreeAccess / isActivatedDomainOwner reflect the same logic purchasePnlPeriods uses", async function () {
      const { premium, deployer, marketplace, nameWrapper, alice } = await loadFixture(deployFixture);
      expect(await premium.isEligibleForFreeAccess(alice.address)).to.equal(false);

      await premium.connect(deployer).setWhitelisted(alice.address, true);
      expect(await premium.isEligibleForFreeAccess(alice.address)).to.equal(true);

      await premium.connect(deployer).setMarketplace(await marketplace.getAddress());
      await premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress());
      const node = ethers.id("alice.etn");
      expect(await premium.isActivatedDomainOwner(alice.address, node)).to.equal(false);
      await marketplace.setActivated(node, true);
      await nameWrapper.setOwner(BigInt(node), alice.address);
      expect(await premium.isActivatedDomainOwner(alice.address, node)).to.equal(true);
    });

    it("reverts when paused", async function () {
      const { premium, deployer, alice } = await loadFixture(deployFixture);
      await premium.connect(deployer).setPaused(true);
      await expect(
        premium.connect(alice).purchasePnlPeriods(alice.address, 1, NO_DOMAIN_CLAIM, { value: await premium.pnlPricePerPeriod() })
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
      await premium.connect(bob).purchasePnlPeriods(bob.address, 1, NO_DOMAIN_CLAIM, { value: await premium.pnlPricePerPeriod() });
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

    it("setErevosShares: owner-only, updates value, emits event", async function () {
      const { premium, deployer, alice, erevos } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setErevosShares(await erevos.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      await expect(premium.connect(deployer).setErevosShares(await erevos.getAddress()))
        .to.emit(premium, "ErevosSharesUpdated")
        .withArgs(await erevos.getAddress());
      expect(await premium.erevosShares()).to.equal(await erevos.getAddress());
    });

    it("setMarketplace / setNameWrapper: owner-only, update values, emit events", async function () {
      const { premium, deployer, alice, marketplace, nameWrapper } = await loadFixture(deployFixture);
      await expect(
        premium.connect(alice).setMarketplace(await marketplace.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");
      await expect(
        premium.connect(alice).setNameWrapper(await nameWrapper.getAddress())
      ).to.be.revertedWithCustomError(premium, "OwnableUnauthorizedAccount");

      await expect(premium.connect(deployer).setMarketplace(await marketplace.getAddress()))
        .to.emit(premium, "MarketplaceUpdated")
        .withArgs(await marketplace.getAddress());
      await expect(premium.connect(deployer).setNameWrapper(await nameWrapper.getAddress()))
        .to.emit(premium, "NameWrapperUpdated")
        .withArgs(await nameWrapper.getAddress());

      expect(await premium.marketplace()).to.equal(await marketplace.getAddress());
      expect(await premium.nameWrapper()).to.equal(await nameWrapper.getAddress());
    });
  });
});
