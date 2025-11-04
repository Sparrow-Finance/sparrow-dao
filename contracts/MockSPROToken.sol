// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";

contract MockSPROToken is ERC20, ERC20Permit, ERC20Votes {
    constructor() 
        ERC20("Sparrow Governance Token", "SPRO") 
        ERC20Permit("Sparrow Governance Token") 
    {
        // Mint 1 billion tokens to deployer
        _mint(msg.sender, 1_000_000_000 * 10**18);
    }

    // The following functions are overrides required by Solidity
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}