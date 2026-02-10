// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract BatchImplementation {
    uint256 public txNonce;

    bytes32 internal constant BATCH_TYPEHASH = keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)");
    bytes32 internal constant CALL_TYPEHASH = keccak256("Call(address to,uint256 value,bytes data)");

    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("BatchAccount")),
            keccak256(bytes("1")),
            block.chainid,
            address(this)
        ));
    }

    function execute(Call[] calldata calls, bytes calldata signature) external payable {
        bytes32[] memory callHashes = new bytes32[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            callHashes[i] = keccak256(abi.encode(
                CALL_TYPEHASH, 
                calls[i].to, 
                calls[i].value, 
                keccak256(calls[i].data)
            ));
        }

        bytes32 structHash = keccak256(abi.encode(
            BATCH_TYPEHASH,
            txNonce,
            keccak256(abi.encodePacked(callHashes))
        ));

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        require(ECDSA.recover(digest, signature) == address(this), "Invalid batch signature");

        txNonce++;
        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, ) = calls[i].to.call{value: calls[i].value}(calls[i].data);
            require(success, "Call failed");
        }
    }

    receive() external payable {}
}