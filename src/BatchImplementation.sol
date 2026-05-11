// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title  BatchImplementation
/// @notice EIP-7702 batch-call implementation for EOA smart accounts.
///         EOAs delegate to this contract via EIP-7702 and authorize batch
///         execution through Mztk7702Execution EIP-712 signatures.
/// @dev    Deployed once; code is shared across all EOAs that delegate to it.
///         Storage is isolated per EOA via ERC-7201 namespaced storage.
contract BatchImplementation {
    // ─── EIP-712 constants ─────────────────────────────────────────────────────

    /// @dev Mztk7702Execution(string prepareId,bytes32 callDataHash,uint256 deadline)
    ///      Matches backend Eip7702ExecutionTypedDataHelper primaryType.
    bytes32 private constant _EXECUTION_TYPEHASH =
        keccak256("Mztk7702Execution(string prepareId,bytes32 callDataHash,uint256 deadline)");

    bytes32 private constant _DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// @dev Must match backend web3.eip712.domain-name (application.yml).
    bytes32 private constant _DOMAIN_NAME_HASH = keccak256(bytes("MomzzangSeven"));

    /// @dev Must match backend web3.eip712.domain-version (application.yml).
    bytes32 private constant _DOMAIN_VERSION_HASH = keccak256(bytes("1"));

    // ─── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @dev ERC-7201 slot derivation:
    ///      inner = keccak256("mztk.batch.storage")
    ///            = 0xc5eac0f2ea9929a3b589e6f1745a052da6ce45e5d41e89decd09f7eef1942ace
    ///      slot  = keccak256(uint256(inner) - 1) & ~bytes32(uint256(0xff))
    ///            = keccak256(0xc5eac0...2acd)    & ~0xff
    ///            = 0x16f289d6ae9e1cb2c42ce14ae5b09f9c96eb53cc5e5cb628e6324ef569e8ad2d
    ///            & ~0xff
    ///            = 0x16f289d6ae9e1cb2c42ce14ae5b09f9c96eb53cc5e5cb628e6324ef569e8ad00
    ///
    ///      Under EIP-7702 the EOA's own storage is used, so slot 0 is unsafe
    ///      (risk of collision with other code the EOA may delegate to).
    ///      Namespaced storage eliminates that risk.
    bytes32 private constant _BATCH_STORAGE_SLOT = 0x16f289d6ae9e1cb2c42ce14ae5b09f9c96eb53cc5e5cb628e6324ef569e8ad00;

    // ─── Types ─────────────────────────────────────────────────────────────────

    /// @dev A single low-level call to execute.
    ///      `value` MUST be 0; native ETH transfers are intentionally unsupported.
    struct Call {
        address to;
        uint256 value;
        bytes data;
    }

    /// @dev Per-EOA replay-protection state, stored at _BATCH_STORAGE_SLOT.
    struct BatchStorage {
        mapping(bytes32 => bool) usedPrepareIds;
    }

    // ─── Errors ────────────────────────────────────────────────────────────────

    /// @dev Recovered signer does not match address(this) (the EOA).
    error InvalidSignature();
    /// @dev block.timestamp > deadline at the time of execution.
    error SignatureExpired();
    /// @dev prepareId was already consumed by a prior execute() call.
    error ReplayDetected();
    /// @dev calls array is empty — nothing to execute.
    error EmptyCalls();
    /// @dev calls[i].to == address(0).
    error InvalidTarget(uint256 index);
    /// @dev msg.value != 0 or calls[i].value != 0.
    error NativeValueNotAllowed();
    /// @dev calls[i].to.call() returned false; returnData contains the inner revert.
    error CallFailed(uint256 index, address target, bytes returnData);

    // ─── Events ────────────────────────────────────────────────────────────────

    /// @dev Emitted on every successful execute(), enabling off-chain tracking
    ///      of execution intents by prepareIdHash.
    event BatchExecuted(bytes32 indexed prepareIdHash, bytes32 indexed callDataHash, address indexed executor);

    // ─── Storage ───────────────────────────────────────────────────────────────

    function _batchStorage() private pure returns (BatchStorage storage s) {
        bytes32 slot = _BATCH_STORAGE_SLOT;
        assembly {
            s.slot := slot
        }
    }

    // ─── EIP-712 helpers ───────────────────────────────────────────────────────

    /// @dev verifyingContract = address(this) which equals the EOA under EIP-7702.
    ///      Domain separator is computed per-call (not cached) because address(this)
    ///      varies per EOA — caching would produce a wrong separator for other EOAs.
    function _domainSeparator() private view returns (bytes32) {
        return
            keccak256(
                abi.encode(_DOMAIN_TYPEHASH, _DOMAIN_NAME_HASH, _DOMAIN_VERSION_HASH, block.chainid, address(this))
            );
    }

    /// @dev Replicates backend Eip7702BatchCallAbi.hashCalls().
    ///      Both sides compute keccak256(abi.encode(Call[])) where each Call is
    ///      a dynamic struct (address, uint256, bytes).
    function _hashCalls(Call[] calldata calls) private pure returns (bytes32) {
        return keccak256(abi.encode(calls));
    }

    // ─── Execute ───────────────────────────────────────────────────────────────

    /// @notice Execute a batch of calls authorized by a Mztk7702Execution EIP-712 signature.
    /// @param  calls     Ordered list of (to, value, data) calls to execute atomically.
    /// @param  prepareId Backend-issued execution intent ID (UUID string); consumed on use.
    /// @param  deadline  Unix timestamp after which the signature is considered expired.
    /// @param  signature EIP-712 signature over Mztk7702Execution, signed by this EOA.
    function execute(Call[] calldata calls, string calldata prepareId, uint256 deadline, bytes calldata signature)
        external
        payable
    {
        // ── Pre-flight guards (fail fast, cheapest checks first) ─────────────

        // Native ETH is not supported in this ERC-20-only flow
        if (msg.value != 0) revert NativeValueNotAllowed();

        // An empty batch carries no intent
        if (calls.length == 0) revert EmptyCalls();

        // Reject expired signatures before touching storage
        if (block.timestamp > deadline) revert SignatureExpired();

        // ── Replay protection ────────────────────────────────────────────────

        bytes32 prepareIdHash = keccak256(bytes(prepareId));
        BatchStorage storage bs = _batchStorage();
        if (bs.usedPrepareIds[prepareIdHash]) revert ReplayDetected();

        // ── Signature verification ───────────────────────────────────────────

        // callDataHash ties the signature to exactly these calls; prevents relay tampering
        bytes32 callDataHash = _hashCalls(calls);

        bytes32 structHash = keccak256(abi.encode(_EXECUTION_TYPEHASH, prepareIdHash, callDataHash, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));

        if (ECDSA.recover(digest, signature) != address(this)) revert InvalidSignature();

        // ── Commit: mark prepareId consumed ──────────────────────────────────
        // Write after all reads to follow checks-effects pattern
        bs.usedPrepareIds[prepareIdHash] = true;

        // ── Execute calls ────────────────────────────────────────────────────

        for (uint256 i = 0; i < calls.length; i++) {
            if (calls[i].to == address(0)) revert InvalidTarget(i);
            if (calls[i].value != 0) revert NativeValueNotAllowed();

            (bool success, bytes memory returnData) = calls[i].to.call(calls[i].data);
            // Preserve the inner revert reason so upstream can identify which
            // escrow operation failed (e.g. DeadlineExpired, UnsupportedToken)
            if (!success) revert CallFailed(i, calls[i].to, returnData);
        }

        emit BatchExecuted(prepareIdHash, callDataHash, msg.sender);
    }

    /// @dev Required to accept ETH that may be forwarded during EIP-7702 delegation
    ///      setup or NFT-related callbacks. execute() itself blocks ETH transfers.
    receive() external payable {}
}
