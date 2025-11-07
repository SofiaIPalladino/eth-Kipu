/**
 * scripts/deploy-mocks-and-kipu.js
 *
 * Deploy MockUSDC, MockUniswapFactoryMock, MockUniswapRouterMock and KipuBankV3.
 * Ajusta la firma del constructor de MockUniswapRouterMock si tu mock difiere.
 *
 * Usage:
 *  npx hardhat run --network localhost scripts/deploy-mocks-and-kipu.js
 *  npx hardhat run --network sepolia  scripts/deploy-mocks-and-kipu.js
 */

const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);

  // 1) Deploy MockUSDC
  const MockUSDC = await ethers.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.deployed();
  console.log("MockUSDC:", usdc.address);

  // 2) Deploy MockUniswapFactoryMock
  const MockFactory = await ethers.getContractFactory("MockUniswapFactoryMock");
  const factory = await MockFactory.deploy();
  await factory.deployed();
  console.log("MockFactory:", factory.address);

  // 3) Deploy MockUniswapRouterMock
  const MockRouter = await ethers.getContractFactory("MockUniswapRouterMock");

  // Try common constructor shapes:
  let router;
  try {
    // Some mocks accept (factory, weth, usdc) or (factory, usdc)
    router = await MockRouter.deploy(factory.address, usdc.address);
    await router.deployed();
    console.log("MockRouter(factory, usdc) deployed at:", router.address);
  } catch (err1) {
    try {
      router = await MockRouter.deploy(factory.address);
      await router.deployed();
      console.log("MockRouter(factory) deployed at:", router.address);
    } catch (err2) {
      console.log("Failed to deploy MockRouter with common signatures. Please edit the script to match your mock's constructor.");
      throw err2;
    }
  }

  // 4) Optionally set pairs in factory for tests (token->USDC)
  // If your mock factory exposes setPair, you can pre-configure pairs here.
  // Example:
  // await factory.setPair(tokenX.address, usdc.address, ethers.constants.AddressZero);

  // 5) Deploy KipuBankV3
  const Kipu = await ethers.getContractFactory("KipuBankV3");
  const bankCapUsd18 = ethers.utils.parseUnits("10000", 18); // 10k USD18
  const perUserLimitUsd18 = ethers.utils.parseUnits("1000", 18); // 1k USD18

  const kipu = await Kipu.deploy(bankCapUsd18, usdc.address, router.address, perUserLimitUsd18);
  await kipu.deployed();

  console.log("KipuBankV3:", kipu.address);

  // Helpful outputs for tests
  console.log("---- SUMMARY ----");
  console.log("MockUSDC:", usdc.address);
  console.log("MockFactory:", factory.address);
  console.log("MockRouter:", router.address);
  console.log("KipuBankV3:", kipu.address);
  console.log("-----------------");

  // If your router does not mint USDC on swap, fund it so swaps can succeed in tests:
  // await usdc.mint(router.address, ethers.utils.parseUnits("1000000", 6));
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});