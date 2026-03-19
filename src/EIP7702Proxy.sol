// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {NonceTracker} from "./NonceTracker.sol";
import {IAccountStateValidator, ACCOUNT_STATE_VALIDATION_SUCCESS} from "./interfaces/IAccountStateValidator.sol";

contract EIP7702Proxy is Proxy {
    bytes32 internal constant _IMPLEMENTATION_SET_TYPEHASH = keccak256(
        "EIP7702ProxyImplementationSet(uint256 chainId,address proxy,uint256 nonce,address currentImplementation,address newImplementation,bytes32 callDataHash,address validator,uint256 expiry)"
    );

    NonceTracker public immutable nonceTracker;
    address internal immutable _receiver;
    address internal immutable _proxy;

    constructor(address nonceTracker_, address receiver) {
        nonceTracker = NonceTracker(nonceTracker_);
        _receiver = receiver;
        _proxy = address(this);
    }

    receive() external payable {}

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("EIP7702Proxy")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function setImplementation(
        address newImplementation,
        bytes calldata callData,
        address validator,
        uint256 expiry,
        bytes calldata signature
    ) external {
        if (block.timestamp >= expiry) revert("Expired");

        bytes32 structHash = keccak256(
            abi.encode(
                _IMPLEMENTATION_SET_TYPEHASH,
                block.chainid,
                _proxy,
                nonceTracker.useNonce(),
                ERC1967Utils.getImplementation(),
                newImplementation,
                keccak256(callData),
                validator,
                expiry
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
        address signer = ECDSA.recover(digest, signature);
        require(signer == address(this), "Invalid signature");

        ERC1967Utils.upgradeToAndCall(newImplementation, callData);

        if (validator != address(0)) {
            bytes4 result = IAccountStateValidator(validator).validateAccountState(address(this), newImplementation);
            if (result != ACCOUNT_STATE_VALIDATION_SUCCESS) revert("Invalid validation");
        }
    }

    function _implementation() internal view override returns (address) {
        address impl = ERC1967Utils.getImplementation();
        return impl == address(0) ? _receiver : impl;
    }
}
