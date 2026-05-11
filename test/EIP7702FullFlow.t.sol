// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

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

    // EIP-712 typehashes for BatchImplementation (Mztk7702Execution)
    bytes32 private constant _EXECUTION_TYPEHASH =
        keccak256("Mztk7702Execution(string prepareId,bytes32 callDataHash,uint256 deadline)");

    function setUp() public {
        tracker = new NonceTracker();
        receiver = new DefaultReceiver();
        impl = new BatchImplementation();
        nft = new MockNFT();
        proxy = new EIP7702Proxy(address(tracker), address(receiver));

        vm.deal(eoa, 10 ether);
        nft.mint(eoa, 7702);
    }

    function _batchDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MomzzangSeven")),
                keccak256(bytes("1")),
                block.chainid,
                eoa // verifyingContract = EOA address under EIP-7702
            )
        );
    }

    function _signBatch(uint256 pk, BatchImplementation.Call[] memory calls, string memory prepareId, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 prepareIdHash = keccak256(bytes(prepareId));
        bytes32 callDataHash = keccak256(abi.encode(calls));
        bytes32 structHash = keccak256(abi.encode(_EXECUTION_TYPEHASH, prepareIdHash, callDataHash, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _batchDomain(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
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

        string memory prepareId = "test-prepare-id-001";
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signBatch(eoaKey, calls, prepareId, deadline);

        vm.prank(sponsor);
        BatchImplementation(payable(eoa)).execute(calls, prepareId, deadline, sig);

        assertEq(nft.ownerOf(7702), address(0x123));
    }
}
