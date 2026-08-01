/* eslint-disable no-undef */
// Right click on the script name and hit "Run" to execute
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Storage", function () {
  it("test initial value", async function () {
    const Storage = await ethers.getContractFactory("Storage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();
    console.log("storage deployed at:" + (await storage.getAddress()));
    expect(await storage.retrieve()).to.equal(0n);
  });
  it("test updating and retrieving updated value", async function () {
    const Storage = await ethers.getContractFactory("Storage");
    const storage = await Storage.deploy();
    await storage.waitForDeployment();
    const storage2 = await ethers.getContractAt("Storage", await storage.getAddress());
    const setValue = await storage2.store(56);
    await setValue.wait();
    expect(await storage2.retrieve()).to.equal(56n);
  });
});
