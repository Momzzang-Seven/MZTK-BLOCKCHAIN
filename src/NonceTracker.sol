// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract NonceTracker {
    mapping(address account => uint256 nonce) public nonces;

    event NonceUsed(address indexed account, uint256 nonce);

    function useNonce() external returns (uint256 nonce) {
        nonce = nonces[msg.sender]++;
        emit NonceUsed(msg.sender, nonce);
    }
}