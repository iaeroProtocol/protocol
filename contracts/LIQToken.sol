// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title LIQToken
 * @notice Governance and mining token for the iAERO protocol
 * @dev Minting controlled by vault with supply cap
 */
contract LIQToken is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant MAX_SUPPLY = 100_000_000 * 1e18; // 100M tokens
    
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    
    constructor() ERC20("Liquid", "LIQ") ERC20Permit("Liquid") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    /**
     * @notice Mint LIQ tokens to a recipient
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Mint to zero address");
        require(amount > 0, "Zero amount");
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        
        _mint(to, amount);
        emit Minted(to, amount);
    }
    
    /**
     * @notice Burn LIQ tokens from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        require(amount > 0, "Zero amount");
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }
    
    /**
     * @notice Check remaining mintable supply
     * @return Remaining tokens that can be minted
     */
    function remainingMintableSupply() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }
}
