// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.24;

import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {GovernorCountingSimpleUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {GovernorSettingsUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {GovernorTimelockControlUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {GovernorVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {GovernorVotesQuorumFractionUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesQuorumFractionUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

contract SparrowGovernor is GovernorUpgradeable, GovernorSettingsUpgradeable, GovernorCountingSimpleUpgradeable, GovernorVotesUpgradeable, GovernorVotesQuorumFractionUpgradeable, GovernorTimelockControlUpgradeable, UUPSUpgradeable {
    
    // Proposal Categories A through E 
    enum ProposalCategory {
        A_Operations,      // = 0
        B_Grants,          // = 1
        C_Treasury,        // = 2
        D_Constitutional,  // = 3
        E_Emergency        // = 4
    }
    
    // STATE VARIABLES
    
    /// @notice Stores which category each proposal belongs to
    /// @dev proposalId => ProposalCategory
    mapping(uint256 => ProposalCategory) public proposalCategories;
    
    /// @notice Stores USD value for treasury proposals (in 18 decimals)
    /// @dev proposalId => USD amount (e.g., 100000e18 = $100,000)
    mapping(uint256 => uint256) public proposalValues;
    
    /// @notice Quorum percentages in basis points (250 = 2.5%)
    uint256 public standardQuorum;
    uint256 public treasuryHeavyQuorum;
    uint256 public constitutionalQuorum;
    
    /// @notice Approval thresholds in basis points (5000 = 50%)
    uint256 public standardThreshold;
    uint256 public treasuryHeavyThreshold;
    uint256 public constitutionalThreshold;
    
    /// @notice Treasury-heavy proposal limits
    uint256 public treasuryHeavyUsdThreshold;  // $100k
    uint256 public treasuryHeavyPercentage;       

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(IVotes _token, TimelockControllerUpgradeable _timelock)
        public
        initializer
    {
        __Governor_init("SparrowGovernor");
        __GovernorSettings_init(2 weeks, 3 days, 1e18);
        __GovernorCountingSimple_init();
        __GovernorVotes_init(_token);
        __GovernorVotesQuorumFraction_init(25);
        __GovernorTimelockControl_init(_timelock);

        // Initialize quorum and threshold variables
        standardQuorum = 250; // 2.5%
        treasuryHeavyQuorum = 1000; // 10%
        constitutionalQuorum = 2000; // 20%
        
        standardThreshold = 5000; // 50%
        treasuryHeavyThreshold = 6000; // 60%
        constitutionalThreshold = 6667; // 66.7%
        
        treasuryHeavyUsdThreshold = 100_000e18; // $100k
        treasuryHeavyPercentage = 200; // 20%
    }

    // CUSTOM PROPOSE FUNCTION

    /// @notice Create a proposal with a specific category
    /// @param targets Array of contract addresses to call
    /// @param values Array of ETH values to send
    /// @param calldatas Array of function calls (encoded)
    /// @param description Human-readable description
    /// @param category The proposal category (A, B, C, D, or E)
    /// @param usdValue For treasury proposals, the USD value being spent
    /// @return proposalId The ID of the created proposal
    function proposeWithCategory(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        ProposalCategory category,
        uint256 usdValue
    ) public returns (uint256) {
        // Call the parent propose function to create the proposal
        uint256 proposalId = propose(targets, values, calldatas, description);
        
        // Store the category for this proposal
        proposalCategories[proposalId] = category;
        
        // If it's a treasury proposal, store the USD value
        if (category == ProposalCategory.C_Treasury) {
            proposalValues[proposalId] = usdValue;
        }
        
        // Emit an event so everyone can see what category it is
        emit ProposalCategorized(proposalId, category, usdValue);
        
        return proposalId;
    }
    
    /// @notice Event emitted when a proposal is categorized
    event ProposalCategorized(
        uint256 indexed proposalId, 
        ProposalCategory category, 
        uint256 usdValue
    );

    // QUORUM LOGIC
    
    /// @notice Check if a treasury proposal is "heavy" (needs higher quorum)
    /// @param proposalId The proposal to check
    /// @return bool True if it's a treasury-heavy proposal
    function isTreasuryHeavy(uint256 proposalId) public view returns (bool) {
        // Only treasury proposals can be "heavy"
        if (proposalCategories[proposalId] != ProposalCategory.C_Treasury) {
            return false;
        }
        
        uint256 value = proposalValues[proposalId];
        
        // Check if it meets either threshold:
        // 1. Spending >= $100k
        // 2. Spending >= 2% of treasury
        return value >= treasuryHeavyUsdThreshold;
        
        // Note: We're not checking treasury % yet because we need
        // a way to get the treasury balance. We'll add that later.
    }
    
        /// @notice Get the quorum required for a proposal at a specific block
    /// @param blockNumber The block number to check supply at
    /// @return uint256 The number of votes needed for quorum
    function quorum(uint256 blockNumber) 
        public 
        view 
        virtual
        override(GovernorUpgradeable, GovernorVotesQuorumFractionUpgradeable)
        returns (uint256) 
    {
        // Get the total supply of SPRO tokens at that block
        uint256 totalSupply = token().getPastTotalSupply(blockNumber);
        
        // Default to standard quorum (2.5%)
        // Note: We can't check proposal category here because we don't have proposalId
        // We'll need to override _countVote or proposalSnapshot instead
        uint256 quorumBasisPoints = standardQuorum;  // 250 = 2.5%
        
        // Calculate: totalSupply * quorumBasisPoints / 10000
        // Example: 1,000,000 tokens * 250 / 10000 = 25,000 tokens needed
        return (totalSupply * quorumBasisPoints) / 10000;
    }
    
    /// @notice Helper function to get quorum for a specific proposal
    /// @param proposalId The proposal ID
    /// @param blockNumber The block number to check supply at
    /// @return uint256 The number of votes needed for quorum
    function proposalQuorum(uint256 proposalId, uint256 blockNumber) 
        public 
        view 
        returns (uint256) 
    {
        // Get the total supply of SPRO tokens at that block
        uint256 totalSupply = token().getPastTotalSupply(blockNumber);
        
        // Get the category of this proposal
        ProposalCategory category = proposalCategories[proposalId];
        
        // Determine quorum based on category
        uint256 quorumBasisPoints;
        
        if (category == ProposalCategory.D_Constitutional) {
            // Constitutional proposals need 20% quorum
            quorumBasisPoints = constitutionalQuorum;  // 2000 = 20%
        } else if (category == ProposalCategory.C_Treasury && isTreasuryHeavy(proposalId)) {
            // Large treasury proposals need 10% quorum
            quorumBasisPoints = treasuryHeavyQuorum;  // 1000 = 10%
        } else {
            // Standard proposals (A, B, C small) need 2.5% quorum
            quorumBasisPoints = standardQuorum;  // 250 = 2.5%
        }
        
        // Calculate: totalSupply * quorumBasisPoints / 10000
        // Example: 1,000,000 tokens * 250 / 10000 = 25,000 tokens needed
        return (totalSupply * quorumBasisPoints) / 10000;
    }
    
    // GOVERNANCE PARAMETER UPDATES
    
    /// @notice Update the standard quorum percentage (for A/B/C proposals)
    /// @param newQuorum New quorum in basis points (e.g., 250 = 2.5%)
    function setStandardQuorum(uint256 newQuorum) external onlyGovernance {
        require(newQuorum <= 5000, "Quorum cannot exceed 50%");
        require(newQuorum >= 100, "Quorum must be at least 1%");
        
        uint256 oldQuorum = standardQuorum;
        standardQuorum = newQuorum;
        
        emit QuorumUpdated("standardQuorum", oldQuorum, newQuorum);
    }
    
    /// @notice Update the treasury-heavy quorum percentage
    /// @param newQuorum New quorum in basis points (e.g., 1000 = 10%)
    function setTreasuryHeavyQuorum(uint256 newQuorum) external onlyGovernance {
        require(newQuorum <= 5000, "Quorum cannot exceed 50%");
        require(newQuorum >= standardQuorum, "Must be >= standard quorum");
        
        uint256 oldQuorum = treasuryHeavyQuorum;
        treasuryHeavyQuorum = newQuorum;
        
        emit QuorumUpdated("treasuryHeavyQuorum", oldQuorum, newQuorum);
    }
    
    /// @notice Update the constitutional quorum percentage
    /// @param newQuorum New quorum in basis points (e.g., 2000 = 20%)
    function setConstitutionalQuorum(uint256 newQuorum) external onlyGovernance {
        require(newQuorum <= 5000, "Quorum cannot exceed 50%");
        require(newQuorum >= treasuryHeavyQuorum, "Must be >= treasury-heavy quorum");
        
        uint256 oldQuorum = constitutionalQuorum;
        constitutionalQuorum = newQuorum;
        
        emit QuorumUpdated("constitutionalQuorum", oldQuorum, newQuorum);
    }
    
    /// @notice Update the treasury-heavy USD threshold
    /// @param newThreshold New threshold in USD (with 18 decimals)
    function setTreasuryHeavyUsdThreshold(uint256 newThreshold) external onlyGovernance {
        require(newThreshold >= 10_000e18, "Threshold must be at least $10k");
        
        uint256 oldThreshold = treasuryHeavyUsdThreshold;
        treasuryHeavyUsdThreshold = newThreshold;
        
        emit ThresholdUpdated("treasuryHeavyUsdThreshold", oldThreshold, newThreshold);
    }
    
    /// @notice Event emitted when a quorum percentage is updated
    event QuorumUpdated(string parameterName, uint256 oldValue, uint256 newValue);
    
    /// @notice Event emitted when a threshold is updated
    event ThresholdUpdated(string parameterName, uint256 oldValue, uint256 newValue);

    function quorumDenominator() public pure override returns (uint256) {
        return 1000;
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyGovernance
    {}

    // The following functions are overrides required by Solidity.

    function state(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (ProposalState)
    {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function proposalThreshold()
        public
        view
        override(GovernorUpgradeable, GovernorSettingsUpgradeable)
        returns (uint256)
    {
        return super.proposalThreshold();
    }

    function _queueOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint48)
    {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(uint256 proposalId, address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
    {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(address[] memory targets, uint256[] memory values, bytes[] memory calldatas, bytes32 descriptionHash)
        internal
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (uint256)
    {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal
        view
        override(GovernorUpgradeable, GovernorTimelockControlUpgradeable)
        returns (address)
    {
        return super._executor();
    }
}
