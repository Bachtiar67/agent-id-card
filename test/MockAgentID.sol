// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal mock of the SPACE ID Agent ID registry (ERC-721 balanceOf
///         only). Used in tests via vm.etch at the real Agent ID address.
contract MockAgentID {
    mapping(address => uint256) public balances;

    function setBalance(address owner, uint256 bal) external {
        balances[owner] = bal;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return balances[owner];
    }
}
