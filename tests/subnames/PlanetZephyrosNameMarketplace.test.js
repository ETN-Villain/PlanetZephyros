const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

const ONE_YEAR = 365 * 24 * 60 * 60;
const PRICE_PER_SECOND = ethers.parseEther("0.000001");
const ROOT_NODE = "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae";

function parentNodeFor(label) {
  const labelHash = ethers.keccak256(ethers.toUtf8Bytes(label));
  return ethers.keccak256(ethers.concat([ROOT_NODE, labelHash]));
}

function subNodeFor(parentNode, label) {
  const labelHash = ethers.keccak256(ethers.toUtf8Bytes(label));
  return ethers.keccak256(ethers.concat([parentNode, labelHash]));
}

describe("PlanetZephyrosNameMarketplace", function () {
  async function deployFixture() {
    const [deployer, projectWallet, alice, bob, carol] = await ethers.getSigners();

    const MockBaseRegistrar = await ethers.getContractFactory("MockBaseRegistrar");
    const base = await MockBaseRegistrar.deploy();

    const MockController = await ethers.getContractFactory("MockETHRegistrarController");
    const controller = await MockController.deploy(await base.getAddress(), PRICE_PER_SECOND);
    await base.setController(await controller.getAddress());

    const MockNameWrapper = await ethers.getContractFactory("MockNameWrapper");
    const wrapper = await MockNameWrapper.deploy(await base.getAddress());

    const MockCoreToken = await ethers.getContractFactory("MockCoreToken");
    const core = await MockCoreToken.deploy();

    const wethDummy = ethers.Wallet.createRandom().address;
    const MockRouter = await ethers.getContractFactory("MockRouter");
    const router = await MockRouter.deploy(await core.getAddress(), wethDummy, 1000n);

    const defaultResolver = ethers.Wallet.createRandom().address;

    const Marketplace = await ethers.getContractFactory("PlanetZephyrosNameMarketplace");
    const marketplace = await Marketplace.deploy(
      await controller.getAddress(),
      await wrapper.getAddress(),
      await base.getAddress(),
      defaultResolver,
      projectWallet.address,
      deployer.address
    );

    return {
      deployer,
      projectWallet,
      alice,
      bob,
      carol,
      base,
      controller,
      wrapper,
      core,
      router,
      marketplace,
      defaultResolver,
    };
  }

  async function commitAndWait(ctx, signer, label, secret, referrer) {
    const commitment = await ctx.marketplace.computeCommitment(label, ONE_YEAR, secret, referrer);
    await ctx.controller.connect(signer).commit(commitment);
    await time.increase(61);
  }

  async function registerName(ctx, signer, label) {
    const secret = ethers.hexlify(ethers.randomBytes(32));
    const referrer = ethers.ZeroHash;
    await commitAndWait(ctx, signer, label, secret, referrer);
    const [basePrice, brokerageFee, totalPrice] = await ctx.marketplace.quoteRegistration(label, ONE_YEAR);
    await ctx.marketplace
      .connect(signer)
      .registerName(label, ONE_YEAR, secret, referrer, signer.address, 0, parentNodeFor(label), {
        value: totalPrice,
      });
    return { basePrice, brokerageFee, totalPrice, secret, referrer };
  }

  /// Simulates a buyer registering directly with ETHRegistrarController and wrapping it
  /// themselves, entirely bypassing the marketplace (no brokerage ever paid).
  async function registerDirect(ctx, signer, label) {
    const { controller, base, wrapper } = ctx;
    const secret = ethers.hexlify(ethers.randomBytes(32));
    const registration = {
      label,
      owner: signer.address,
      duration: ONE_YEAR,
      secret,
      resolver: ethers.ZeroAddress,
      data: [],
      reverseRecord: 0,
      referrer: ethers.ZeroHash,
    };
    const commitment = await controller.makeCommitment(registration);
    await controller.connect(signer).commit(commitment);
    await time.increase(61);

    const price = await controller.rentPrice(label, ONE_YEAR);
    await controller.connect(signer).register(registration, { value: price.base + price.premium });

    const registrarId = ethers.keccak256(ethers.toUtf8Bytes(label));
    await base.connect(signer).approve(await wrapper.getAddress(), registrarId);
    await wrapper.connect(signer).wrapETH2LD(label, signer.address, 0, ethers.ZeroAddress);

    return { node: parentNodeFor(label) };
  }

  async function withRegisteredParent(label = "alice") {
    const ctx = await loadFixture(deployFixture);
    await registerName(ctx, ctx.alice, label);
    return ctx;
  }

  describe("constructor", function () {
    it("reverts on zero addresses", async function () {
      const { controller, wrapper, base, projectWallet, deployer, defaultResolver } = await loadFixture(deployFixture);
      const Marketplace = await ethers.getContractFactory("PlanetZephyrosNameMarketplace");

      await expect(
        Marketplace.deploy(
          ethers.ZeroAddress,
          await wrapper.getAddress(),
          await base.getAddress(),
          defaultResolver,
          projectWallet.address,
          deployer.address
        )
      ).to.be.revertedWith("Zero registrar controller");

      await expect(
        Marketplace.deploy(
          await controller.getAddress(),
          ethers.ZeroAddress,
          await base.getAddress(),
          defaultResolver,
          projectWallet.address,
          deployer.address
        )
      ).to.be.revertedWith("Zero name wrapper");

      await expect(
        Marketplace.deploy(
          await controller.getAddress(),
          await wrapper.getAddress(),
          ethers.ZeroAddress,
          defaultResolver,
          projectWallet.address,
          deployer.address
        )
      ).to.be.revertedWith("Zero base registrar");

      await expect(
        Marketplace.deploy(
          await controller.getAddress(),
          await wrapper.getAddress(),
          await base.getAddress(),
          defaultResolver,
          ethers.ZeroAddress,
          deployer.address
        )
      ).to.be.revertedWith("Zero project wallet");
    });
  });

  describe("registerName", function () {
    it("registers, wraps to buyer, pays brokerage, refunds overpayment", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, wrapper, projectWallet, alice } = ctx;
      const label = "alice";
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const referrer = ethers.ZeroHash;
      await commitAndWait(ctx, alice, label, secret, referrer);

      const [basePrice, brokerageFee, totalPrice] = await marketplace.quoteRegistration(label, ONE_YEAR);
      expect(brokerageFee).to.equal((basePrice * 5000n) / 10000n);

      const overpay = totalPrice + ethers.parseEther("1");
      const projectBalanceBefore = await ethers.provider.getBalance(projectWallet.address);
      const aliceBalanceBefore = await ethers.provider.getBalance(alice.address);

      const tx = await marketplace
        .connect(alice)
        .registerName(label, ONE_YEAR, secret, referrer, alice.address, 0, parentNodeFor(label), {
          value: overpay,
        });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;

      expect(await wrapper.ownerOf(BigInt(parentNodeFor(label)))).to.equal(alice.address);
      expect(await marketplace.domainActivated(parentNodeFor(label))).to.equal(true);

      const projectBalanceAfter = await ethers.provider.getBalance(projectWallet.address);
      expect(projectBalanceAfter - projectBalanceBefore).to.equal(brokerageFee);

      const aliceBalanceAfter = await ethers.provider.getBalance(alice.address);
      expect(aliceBalanceBefore - aliceBalanceAfter).to.equal(totalPrice + gasCost);
    });

    it("reverts on insufficient payment", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice } = ctx;
      const label = "bob";
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const referrer = ethers.ZeroHash;
      await commitAndWait(ctx, alice, label, secret, referrer);
      const [, , totalPrice] = await marketplace.quoteRegistration(label, ONE_YEAR);

      await expect(
        marketplace
          .connect(alice)
          .registerName(label, ONE_YEAR, secret, referrer, alice.address, 0, parentNodeFor(label), {
            value: totalPrice - 1n,
          })
      ).to.be.revertedWith("Insufficient payment");
    });

    it("reverts on zero wrapped owner", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice } = ctx;
      const label = "carol";
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const referrer = ethers.ZeroHash;
      await commitAndWait(ctx, alice, label, secret, referrer);
      const [, , totalPrice] = await marketplace.quoteRegistration(label, ONE_YEAR);

      await expect(
        marketplace
          .connect(alice)
          .registerName(label, ONE_YEAR, secret, referrer, ethers.ZeroAddress, 0, parentNodeFor(label), {
            value: totalPrice,
          })
      ).to.be.revertedWith("Zero wrapped owner");
    });

    it("reverts while paused", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, deployer, alice } = ctx;
      await marketplace.connect(deployer).setPaused(true);
      const label = "dave";
      const secret = ethers.hexlify(ethers.randomBytes(32));
      const referrer = ethers.ZeroHash;
      await commitAndWait(ctx, alice, label, secret, referrer);
      const [, , totalPrice] = await marketplace.quoteRegistration(label, ONE_YEAR);

      await expect(
        marketplace
          .connect(alice)
          .registerName(label, ONE_YEAR, secret, referrer, alice.address, 0, parentNodeFor(label), {
            value: totalPrice,
          })
      ).to.be.revertedWith("Marketplace paused");
    });
  });

  describe("setBrokerageBps", function () {
    it("only owner can set, respects ceiling", async function () {
      const { marketplace, deployer, alice } = await loadFixture(deployFixture);
      await expect(marketplace.connect(alice).setBrokerageBps(1000)).to.be.revertedWithCustomError(
        marketplace,
        "OwnableUnauthorizedAccount"
      );
      await expect(marketplace.connect(deployer).setBrokerageBps(5001)).to.be.revertedWith("Brokerage too high");
      await marketplace.connect(deployer).setBrokerageBps(1000);
      expect(await marketplace.brokerageBps()).to.equal(1000);
    });
  });

  describe("subname marketplace", function () {
    it("listSubname reverts if caller doesn't control parent", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, bob } = ctx;
      const parentNode = parentNodeFor("alice");
      await expect(
        marketplace.connect(bob).listSubname(parentNode, "shop", 0, 0, ethers.parseEther("1"))
      ).to.be.revertedWith("Not parent owner/operator");
    });

    it("listSubname reverts if marketplace not approved", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, alice } = ctx;
      const parentNode = parentNodeFor("alice");
      await expect(
        marketplace.connect(alice).listSubname(parentNode, "shop", 0, 0, ethers.parseEther("1"))
      ).to.be.revertedWith("Marketplace not approved");
    });

    it("lists and buys a new subname, splitting 80/20 and wrapping to the buyer", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);

      const price = ethers.parseEther("2");
      const sellerAmount = (price * 8000n) / 10000n;
      const burnAmount = (price * 2000n) / 10000n;

      await expect(marketplace.connect(alice).listSubname(parentNode, "shop", 0, 0, price))
        .to.emit(marketplace, "SubnameListed")
        .withArgs(1n, alice.address, parentNode, "shop", price);

      const aliceBalanceBefore = await ethers.provider.getBalance(alice.address);

      await expect(marketplace.connect(bob).buyListing(1, { value: price }))
        .to.emit(marketplace, "ListingSold")
        .withArgs(1n, bob.address, alice.address, price, sellerAmount, burnAmount);

      const aliceBalanceAfter = await ethers.provider.getBalance(alice.address);
      expect(aliceBalanceAfter - aliceBalanceBefore).to.equal(sellerAmount);
      expect(await marketplace.burnPool()).to.equal(burnAmount);

      const subNode = subNodeFor(parentNode, "shop");
      expect(await wrapper.ownerOf(BigInt(subNode))).to.equal(bob.address);
    });

    it("refunds overpayment on buyListing", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      const price = ethers.parseEther("1");
      await marketplace.connect(alice).listSubname(parentNode, "over", 0, 0, price);

      const bobBalanceBefore = await ethers.provider.getBalance(bob.address);
      const tx = await marketplace.connect(bob).buyListing(1, { value: price + ethers.parseEther("1") });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;
      const bobBalanceAfter = await ethers.provider.getBalance(bob.address);
      expect(bobBalanceBefore - bobBalanceAfter).to.equal(price + gasCost);
    });

    it("cannot buy the same listing twice", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob, carol } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      const price = ethers.parseEther("1");
      await marketplace.connect(alice).listSubname(parentNode, "twice", 0, 0, price);
      await marketplace.connect(bob).buyListing(1, { value: price });
      await expect(marketplace.connect(carol).buyListing(1, { value: price })).to.be.revertedWith("Not active");
    });

    it("cancelListing: seller or contract owner can cancel, others cannot", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob, deployer } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);

      await marketplace.connect(alice).listSubname(parentNode, "cancelme", 0, 0, ethers.parseEther("1"));
      await expect(marketplace.connect(bob).cancelListing(1)).to.be.revertedWith("Not authorised");

      await marketplace.connect(alice).listSubname(parentNode, "cancelme2", 0, 0, ethers.parseEther("1"));
      await marketplace.connect(deployer).cancelListing(2);
      await expect(marketplace.connect(bob).buyListing(2, { value: ethers.parseEther("1") })).to.be.revertedWith(
        "Not active"
      );

      await marketplace.connect(alice).cancelListing(1);
      await expect(marketplace.connect(bob).buyListing(1, { value: ethers.parseEther("1") })).to.be.revertedWith(
        "Not active"
      );
    });

    it("resells an existing wrapped name (ExistingWrappedName listing)", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob } = ctx;
      const tokenId = BigInt(parentNodeFor("alice"));
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);

      const price = ethers.parseEther("3");
      await expect(marketplace.connect(alice).listExistingName(tokenId, price))
        .to.emit(marketplace, "ExistingNameListed")
        .withArgs(1n, alice.address, tokenId, price);

      await marketplace.connect(bob).buyListing(1, { value: price });

      expect(await wrapper.ownerOf(tokenId)).to.equal(bob.address);
    });

    it("listExistingName reverts if not token owner", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, bob } = ctx;
      const tokenId = BigInt(parentNodeFor("alice"));
      await expect(
        marketplace.connect(bob).listExistingName(tokenId, ethers.parseEther("1"))
      ).to.be.revertedWith("Not token owner");
    });

    it("a subname created via buyListing is itself immediately activated for resale", async function () {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob, carol } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      await marketplace.connect(alice).listSubname(parentNode, "shop", 0, 0, ethers.parseEther("1"));
      await marketplace.connect(bob).buyListing(1, { value: ethers.parseEther("1") });

      const subNode = subNodeFor(parentNode, "shop");
      expect(await marketplace.domainActivated(subNode)).to.equal(true);

      await wrapper.connect(bob).setApprovalForAll(await marketplace.getAddress(), true);
      await expect(marketplace.connect(bob).listExistingName(BigInt(subNode), ethers.parseEther("2"))).to.not.be
        .reverted;
      await marketplace.connect(carol).buyListing(2, { value: ethers.parseEther("2") });
      expect(await wrapper.ownerOf(BigInt(subNode))).to.equal(carol.address);
    });
  });

  describe("domain activation (bypassing the marketplace at registration)", function () {
    it("listSubname reverts on a directly-registered (never activated) domain", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, wrapper, alice } = ctx;
      const label = "direct";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      await expect(
        marketplace.connect(alice).listSubname(node, "shop", 0, 0, ethers.parseEther("1"))
      ).to.be.revertedWith("Domain not activated");
    });

    it("listExistingName reverts on a directly-registered (never activated) domain", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, wrapper, alice } = ctx;
      const label = "direct2";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      await expect(
        marketplace.connect(alice).listExistingName(BigInt(node), ethers.parseEther("1"))
      ).to.be.revertedWith("Domain not activated");
    });

    it("activateDomain reverts if caller doesn't own the name", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice, bob } = ctx;
      const label = "direct3";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await expect(
        marketplace.connect(bob).activateDomain(node, label, { value: ethers.parseEther("1000") })
      ).to.be.revertedWith("Not name owner");
    });

    it("activateDomain reverts on label mismatch", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice } = ctx;
      const label = "direct4";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await expect(
        marketplace.connect(alice).activateDomain(node, "wronglabel", { value: ethers.parseEther("1000") })
      ).to.be.revertedWith("Label mismatch");
    });

    it("activateDomain reverts on insufficient payment", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice } = ctx;
      const label = "direct5";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await expect(marketplace.connect(alice).activateDomain(node, label, { value: 0 })).to.be.revertedWith(
        "Insufficient payment"
      );
    });

    it("activateDomain: happy path unlocks listSubname, pays projectWallet, refunds excess", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, wrapper, projectWallet, alice } = ctx;
      const label = "direct6";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      const projectBalanceBefore = await ethers.provider.getBalance(projectWallet.address);
      const aliceBalanceBefore = await ethers.provider.getBalance(alice.address);

      const tx = await marketplace.connect(alice).activateDomain(node, label, { value: ethers.parseEther("1000") });
      const receipt = await tx.wait();
      const gasCost = receipt.gasUsed * receipt.gasPrice;

      const event = receipt.logs
        .map((l) => {
          try {
            return marketplace.interface.parseLog(l);
          } catch {
            return null;
          }
        })
        .find((e) => e && e.name === "DomainActivated");
      expect(event).to.not.equal(undefined);
      const feePaid = event.args.feePaid;
      expect(feePaid).to.be.gt(0n);

      expect(await marketplace.domainActivated(node)).to.equal(true);

      const projectBalanceAfter = await ethers.provider.getBalance(projectWallet.address);
      expect(projectBalanceAfter - projectBalanceBefore).to.equal(feePaid);

      const aliceBalanceAfter = await ethers.provider.getBalance(alice.address);
      expect(aliceBalanceBefore - aliceBalanceAfter).to.equal(feePaid + gasCost);

      // Now unlocked: listSubname should succeed.
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      await expect(marketplace.connect(alice).listSubname(node, "shop", 0, 0, ethers.parseEther("1"))).to.not.be
        .reverted;
    });

    it("activateDomain reverts if already activated", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, alice } = ctx;
      const label = "direct7";
      await registerDirect(ctx, alice, label);
      const node = parentNodeFor(label);

      await marketplace.connect(alice).activateDomain(node, label, { value: ethers.parseEther("1000") });
      await expect(
        marketplace.connect(alice).activateDomain(node, label, { value: ethers.parseEther("1000") })
      ).to.be.revertedWith("Already activated");
    });
  });

  describe("buyback and burn", function () {
    async function withBurnPool() {
      const ctx = await withRegisteredParent();
      const { marketplace, wrapper, alice, bob } = ctx;
      const parentNode = parentNodeFor("alice");
      await wrapper.connect(alice).setApprovalForAll(await marketplace.getAddress(), true);
      const price = ethers.parseEther("5");
      await marketplace.connect(alice).listSubname(parentNode, "shop", 0, 0, price);
      await marketplace.connect(bob).buyListing(1, { value: price });
      return ctx;
    }

    it("reverts if not configured", async function () {
      const ctx = await withBurnPool();
      const { marketplace, deployer } = ctx;
      const deadline = (await time.latest()) + 300;
      await expect(marketplace.connect(deployer).buyBackAndBurn(0, deadline)).to.be.revertedWith(
        "Buyback not configured"
      );
    });

    it("reverts if caller is not owner", async function () {
      const ctx = await withBurnPool();
      const { marketplace, alice } = ctx;
      const deadline = (await time.latest()) + 300;
      await expect(marketplace.connect(alice).buyBackAndBurn(0, deadline)).to.be.revertedWithCustomError(
        marketplace,
        "OwnableUnauthorizedAccount"
      );
    });

    it("reverts if there is nothing to burn", async function () {
      const ctx = await loadFixture(deployFixture);
      const { marketplace, core, router, deployer } = ctx;
      await marketplace.connect(deployer).setCoreToken(await core.getAddress());
      await marketplace.connect(deployer).setSwapRouter(await router.getAddress());
      const deadline = (await time.latest()) + 300;
      await expect(marketplace.connect(deployer).buyBackAndBurn(0, deadline)).to.be.revertedWith(
        "Nothing to burn"
      );
    });

    it("swaps the pool for CORE and burns it", async function () {
      const ctx = await withBurnPool();
      const { marketplace, core, router, deployer } = ctx;
      await marketplace.connect(deployer).setCoreToken(await core.getAddress());
      await marketplace.connect(deployer).setSwapRouter(await router.getAddress());

      const burnPool = await marketplace.burnPool();
      expect(burnPool).to.be.gt(0);
      const rate = await router.rate();

      const deadline = (await time.latest()) + 300;
      await expect(marketplace.connect(deployer).buyBackAndBurn(0, deadline))
        .to.emit(marketplace, "BuybackAndBurn")
        .withArgs(burnPool, burnPool * rate);

      expect(await marketplace.burnPool()).to.equal(0);
      expect(await marketplace.totalCoreBurned()).to.equal(burnPool * rate);
      expect(await core.totalSupply()).to.equal(0); // minted then burned within the same tx
    });

    it("reverts on slippage when minCoreOut cannot be met", async function () {
      const ctx = await withBurnPool();
      const { marketplace, core, router, deployer } = ctx;
      await marketplace.connect(deployer).setCoreToken(await core.getAddress());
      await marketplace.connect(deployer).setSwapRouter(await router.getAddress());

      const burnPool = await marketplace.burnPool();
      const rate = await router.rate();
      const deadline = (await time.latest()) + 300;

      await expect(
        marketplace.connect(deployer).buyBackAndBurn(burnPool * rate + 1n, deadline)
      ).to.be.revertedWith("Insufficient output amount");
      expect(await marketplace.burnPool()).to.equal(burnPool); // reverted tx leaves pool untouched
    });
  });

  describe("admin", function () {
    it("setProjectWallet rejects zero address and non-owner callers", async function () {
      const { marketplace, deployer, alice, bob } = await loadFixture(deployFixture);
      await expect(marketplace.connect(alice).setProjectWallet(bob.address)).to.be.revertedWithCustomError(
        marketplace,
        "OwnableUnauthorizedAccount"
      );
      await expect(marketplace.connect(deployer).setProjectWallet(ethers.ZeroAddress)).to.be.revertedWith(
        "Zero address"
      );
      await marketplace.connect(deployer).setProjectWallet(bob.address);
      expect(await marketplace.projectWallet()).to.equal(bob.address);
    });

    it("setPaused blocks marketplace actions and setCoreToken/setSwapRouter are owner-only", async function () {
      const { marketplace, deployer, alice } = await loadFixture(deployFixture);
      await expect(marketplace.connect(alice).setCoreToken(alice.address)).to.be.revertedWithCustomError(
        marketplace,
        "OwnableUnauthorizedAccount"
      );
      await expect(marketplace.connect(alice).setSwapRouter(alice.address)).to.be.revertedWithCustomError(
        marketplace,
        "OwnableUnauthorizedAccount"
      );
      await marketplace.connect(deployer).setPaused(true);
      expect(await marketplace.paused()).to.equal(true);
    });

    it("rescueTokens transfers accidentally sent ERC20 out of the contract", async function () {
      const { marketplace, core, deployer, alice } = await loadFixture(deployFixture);
      await core.mint(await marketplace.getAddress(), ethers.parseEther("10"));
      await marketplace.connect(deployer).rescueTokens(await core.getAddress(), ethers.parseEther("10"), alice.address);
      expect(await core.balanceOf(alice.address)).to.equal(ethers.parseEther("10"));
    });
  });
});
