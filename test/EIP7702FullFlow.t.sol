// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {EIP7702Proxy} from "../src/EIP7702Proxy.sol";
import {NonceTracker} from "../src/NonceTracker.sol";
import {DefaultReceiver} from "../src/DefaultReceiver.sol";
import {BatchImplementation} from "../src/BatchImplementation.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("MZTK NFT", "MZTK") {}

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}

contract EIP7702FullFlowTest is Test {
    EIP7702Proxy proxy;
    NonceTracker tracker;
    DefaultReceiver receiver;
    BatchImplementation impl;
    MockNFT nft;

    uint256 eoaKey = 0x1111;
    address eoa = vm.addr(eoaKey);
    address sponsor = address(0x9999);

    function setUp() public {
        tracker = new NonceTracker();
        receiver = new DefaultReceiver();
        impl = new BatchImplementation();
        nft = new MockNFT();
        proxy = new EIP7702Proxy(address(tracker), address(receiver));

        vm.deal(eoa, 10 ether);
        nft.mint(eoa, 7702);
    }

    function test_EIP712_Full_Lifecycle() public {
        vm.etch(eoa, address(proxy).code);

        uint256 expiry = block.timestamp + 1 hours;
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("EIP7702Proxy")),
                keccak256(bytes("1")),
                block.chainid,
                eoa
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "EIP7702ProxyImplementationSet(uint256 chainId,address proxy,uint256 nonce,address currentImplementation,address newImplementation,bytes32 callDataHash,address validator,uint256 expiry)"
                ),
                block.chainid,
                address(proxy),
                0,
                address(0),
                address(impl),
                keccak256(""),
                address(0),
                expiry
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(eoaKey, digest);

        vm.prank(sponsor);
        EIP7702Proxy(payable(eoa))
            .setImplementation(address(impl), "", address(0), expiry, abi.encodePacked(r1, s1, v1));

        BatchImplementation.Call[] memory calls = new BatchImplementation.Call[](1);
        calls[0] = BatchImplementation.Call({
            to: address(nft),
            value: 0,
            data: abi.encodeWithSelector(nft.transferFrom.selector, eoa, address(0x123), 7702)
        });

        bytes32[] memory callHashes = new bytes32[](1);
        callHashes[0] = keccak256(
            abi.encode(keccak256("Call(address to,uint256 value,bytes data)"), calls[0].to, 0, keccak256(calls[0].data))
        );
        bytes32 batchStructHash = keccak256(
            abi.encode(
                keccak256("Batch(uint256 nonce,Call[] calls)Call(address to,uint256 value,bytes data)"),
                0,
                keccak256(abi.encodePacked(callHashes))
            )
        );
        bytes32 batchDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("BatchAccount")),
                keccak256(bytes("1")),
                block.chainid,
                eoa
            )
        );
        bytes32 batchDigest = keccak256(abi.encodePacked("\x19\x01", batchDomain, batchStructHash));
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(eoaKey, batchDigest);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, abi.encodePacked(r2, s2, v2));

        assertEq(nft.ownerOf(7702), address(0x123));
    }
}
