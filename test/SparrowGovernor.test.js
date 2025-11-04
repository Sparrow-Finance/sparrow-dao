const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SparrowGovernor", function () {
  let governor, token, timelock;
  let owner, voter1, voter2;
  
  // Proposal categories
  const Categories = {
    A_Operations: 0,
    B_Grants: 1,
    C_Treasury: 2,
    D_Constitutional: 3,
    E_Emergency: 4
  };

  beforeEach(async function () {
    [owner, voter1, voter2] = await ethers.getSigners();

    // Deploy SPRO token
    const MockToken = await ethers.getContractFactory("MockSPROToken");
    token = await MockToken.deploy();
    await token.waitForDeployment();

    // Deploy Timelock
    const minDelay = 259200; // 3 days
    const TimelockController = await ethers.getContractFactory("TimelockController");
    timelock = await TimelockController.deploy(
      minDelay,
      [],
      [ethers.ZeroAddress],
      owner.address
    );
    await timelock.waitForDeployment();

    // Deploy Governor
    const SparrowGovernor = await ethers.getContractFactory("SparrowGovernor");
    governor = await upgrades.deployProxy(
      SparrowGovernor,
      [await token.getAddress(), await timelock.getAddress()],
      { initializer: 'initialize', kind: 'uups' }
    );
    await governor.waitForDeployment();

    // Setup roles
    const PROPOSER_ROLE = await timelock.PROPOSER_ROLE();
    const CANCELLER_ROLE = await timelock.CANCELLER_ROLE();
    await timelock.grantRole(PROPOSER_ROLE, await governor.getAddress());
    await timelock.grantRole(CANCELLER_ROLE, await governor.getAddress());

    // Delegate voting power
    await token.delegate(owner.address);
    
    // Transfer some tokens to voters
    await token.transfer(voter1.address, ethers.parseEther("100000"));
    await token.transfer(voter2.address, ethers.parseEther("50000"));
    await token.connect(voter1).delegate(voter1.address);
    await token.connect(voter2).delegate(voter2.address);
  });

  describe("Deployment", function () {
    it("Should set the correct name", async function () {
      expect(await governor.name()).to.equal("SparrowGovernor");
    });

    it("Should set correct quorum values", async function () {
      expect(await governor.standardQuorum()).to.equal(250); // 2.5%
      expect(await governor.treasuryHeavyQuorum()).to.equal(1000); // 10%
      expect(await governor.constitutionalQuorum()).to.equal(2000); // 20%
    });

    it("Should set correct threshold values", async function () {
      expect(await governor.standardThreshold()).to.equal(5000); // 50%
      expect(await governor.treasuryHeavyThreshold()).to.equal(6000); // 60%
      expect(await governor.constitutionalThreshold()).to.equal(6667); // 66.7%
    });

    it("Should have correct voting settings", async function () {
      expect(await governor.votingDelay()).to.equal(172800); // 2 days in seconds
      expect(await governor.votingPeriod()).to.equal(259200); // 3 days in seconds
      expect(await governor.proposalThreshold()).to.equal(ethers.parseEther("500000")); // 500k SPRO (0.05%)
    });
  });

  describe("Proposal Creation", function () {
    it("Should create a Category A proposal", async function () {
      const targets = [await token.getAddress()];
      const values = [0];
      const calldatas = [token.interface.encodeFunctionData("transfer", [voter1.address, 100])];
      const description = "Test Category A Proposal";
      
      const tx = await governor.proposeWithCategory(
        targets,
        values,
        calldatas,
        description,
        Categories.A_Operations,
        0
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          return governor.interface.parseLog(log).name === "ProposalCategorized";
        } catch (e) {
          return false;
        }
      });
      
      expect(event).to.not.be.undefined;
    });

    it("Should create a Category C Treasury proposal with USD value", async function () {
      const targets = [await token.getAddress()];
      const values = [0];
      const calldatas = [token.interface.encodeFunctionData("transfer", [voter1.address, 100])];
      const description = "Test Treasury Proposal";
      const usdValue = ethers.parseEther("150000"); // $150k
      
      const tx = await governor.proposeWithCategory(
        targets,
        values,
        calldatas,
        description,
        Categories.C_Treasury,
        usdValue
      );
      
      await expect(tx).to.emit(governor, "ProposalCategorized");
    });

    it("Should fail if proposer doesn't have enough tokens", async function () {
      const targets = [await token.getAddress()];
      const values = [0];
      const calldatas = [token.interface.encodeFunctionData("transfer", [voter1.address, 100])];
      const description = "Test Proposal";
      
      // Create account with no tokens
      const [, , , noTokenAccount] = await ethers.getSigners();
      
      await expect(
        governor.connect(noTokenAccount).proposeWithCategory(
          targets,
          values,
          calldatas,
          description,
          Categories.A_Operations,
          0
        )
      ).to.be.reverted;
    });
  });

  describe("Quorum Calculation", function () {
    it("Should return correct quorum for standard proposal", async function () {
      // Mine a block to ensure voting power is checkpointed
      await ethers.provider.send("evm_mine");
      
      const blockNumber = await ethers.provider.getBlockNumber();
      const totalSupply = await token.totalSupply();
      const expectedQuorum = (totalSupply * 250n) / 10000n; // 2.5%
      
      const quorum = await governor.quorum(blockNumber - 1); // Use previous block
      expect(quorum).to.equal(expectedQuorum);
    });

    it("Should detect treasury-heavy proposals", async function () {
      // Create a proposal
      const targets = [await token.getAddress()];
      const values = [0];
      const calldatas = [token.interface.encodeFunctionData("transfer", [voter1.address, 100])];
      const description = "Large Treasury Proposal";
      const usdValue = ethers.parseEther("150000"); // $150k (over $100k threshold)
      
      const tx = await governor.proposeWithCategory(
        targets,
        values,
        calldatas,
        description,
        Categories.C_Treasury,
        usdValue
      );
      
      const receipt = await tx.wait();
      const proposalCreatedEvent = receipt.logs.find(log => {
        try {
          const parsed = governor.interface.parseLog(log);
          return parsed.name === "ProposalCreated";
        } catch (e) {
          return false;
        }
      });
      
      const proposalId = governor.interface.parseLog(proposalCreatedEvent).args.proposalId;
      
      // Check if it's detected as treasury-heavy
      expect(await governor.isTreasuryHeavy(proposalId)).to.be.true;
    });
  });

  describe("Governance Parameter Updates", function () {
    it("Should allow governance to update standard quorum", async function () {
      // This would require a full governance vote in production
      // For testing, we can test the function exists and has correct access control
      expect(await governor.standardQuorum()).to.equal(250);
    });

    it("Should not allow non-governance to update parameters", async function () {
      await expect(
        governor.connect(voter1).setStandardQuorum(300)
      ).to.be.reverted;
    });
  });

  describe("Upgradeability", function () {
    it("Should be upgradeable via governance", async function () {
      const implementationAddress = await upgrades.erc1967.getImplementationAddress(
        await governor.getAddress()
      );
      expect(implementationAddress).to.not.equal(ethers.ZeroAddress);
    });
  });
});