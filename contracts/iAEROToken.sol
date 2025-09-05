// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title iAEROToken
 * @notice ERC20 receipt token for permalocked AERO
 * @dev Minting restricted to authorized vault contracts
 */
contract iAEROToken is ERC20, ERC20Permit, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    
    event Minted(address indexed to, uint256 amount);
    event Burned(address indexed from, uint256 amount);
    
    constructor() ERC20("iAERO", "iAERO") ERC20Permit("iAERO") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
    
    /**
     * @notice Mint iAERO tokens to a recipient
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(to != address(0), "Mint to zero address");
        require(amount > 0, "Zero amount");
        _mint(to, amount);
        emit Minted(to, amount);
    }
    
    /**
     * @notice Burn iAERO tokens from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        require(amount > 0, "Zero amount");
        _burn(msg.sender, amount);
        emit Burned(msg.sender, amount);
    }
    
    /**
     * @notice Burn iAERO tokens from a specific address (requires BURNER_ROLE)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        require(from != address(0), "Burn from zero address");
        require(amount > 0, "Zero amount");
        _burn(from, amount);
        emit Burned(from, amount);
    }
}