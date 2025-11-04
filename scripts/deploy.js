const { ethers, upgrades } = require("hardhat");

async function main() {
  console.log("Starting deployment...\n");

  // Get signers
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "ETH\n");

  // Step 1: Deploy a mock SPRO token (ERC20Votes)
  console.log("1. Deploying mock SPRO token...");
  const MockToken = await ethers.getContractFactory("MockSPROToken");
  const token = await MockToken.deploy();
  await token.waitForDeployment();
  const tokenAddress = await token.getAddress();
  console.log("✅ SPRO Token deployed to:", tokenAddress, "\n");

   // Step 2: Deploy TimelockController (non-upgradeable)
  console.log("2. Deploying TimelockController...");
  const minDelay = 259200; // 3 days in seconds (72 hours)
  const proposers = []; // Will be set to Governor after deployment
  const executors = [ethers.ZeroAddress]; // Anyone can execute after timelock
  const admin = deployer.address; // Deployer is initial admin
  
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockController.deploy(minDelay, proposers, executors, admin);
  await timelock.waitForDeployment();
  const timelockAddress = await timelock.getAddress();
  console.log("✅ Timelock deployed to:", timelockAddress, "\n");

  // Step 3: Deploy SparrowGovernor
  console.log("3. Deploying SparrowGovernor...");
  const SparrowGovernor = await ethers.getContractFactory("SparrowGovernor");
  const governor = await upgrades.deployProxy(
    SparrowGovernor,
    [tokenAddress, timelockAddress],
    { 
      initializer: 'initialize',
      kind: 'uups'
    }
  );
  await governor.waitForDeployment();
  const governorAddress = await governor.getAddress();
  console.log("✅ SparrowGovernor deployed to:", governorAddress);
  
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(governorAddress);
  console.log("   Implementation address:", implementationAddress, "\n");

  // Step 4: Grant roles to Governor in Timelock
  console.log("4. Setting up Timelock roles...");
  const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
  const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
  
  // Grant proposer role to Governor
  await timelock.grantRole(PROPOSER_ROLE, governorAddress);
  console.log("   ✅ Granted PROPOSER_ROLE to Governor");
  
  // Grant canceller role to Governor
  await timelock.grantRole(CANCELLER_ROLE, governorAddress);
  console.log("   ✅ Granted CANCELLER_ROLE to Governor\n");

  // Step 5: Delegate voting power to deployer (so we can test voting)
  console.log("5. Setting up voting power...");
  await token.delegate(deployer.address);
  console.log("   ✅ Delegated voting power to deployer\n");

  // Summary
  console.log("=".repeat(60));
  console.log("DEPLOYMENT SUMMARY");
  console.log("=".repeat(60));
  console.log("SPRO Token:        ", tokenAddress);
  console.log("Timelock:          ", timelockAddress);
  console.log("Governor:          ", governorAddress);
  console.log("Implementation:    ", implementationAddress);
  console.log("Deployer:          ", deployer.address);
  console.log("=".repeat(60));
  console.log("\n✅ All contracts deployed successfully!\n");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });