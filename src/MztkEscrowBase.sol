// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IEscrowBase} from "./interfaces/IEscrowBase.sol";

/// @title  MztkEscrowBase
/// @notice Abstract base contract that implements the shared administrative
///         infrastructure present in every MZTK escrow:
///           • server-signer + EIP-712 signature verification window
///           • ERC-20 token whitelist
///           • relayer ACL + onlyRelayerOrOwner modifier
///           • default escrow deadline duration management
/// @dev    Both MarketplaceEscrow and QnAEscrow inherit this contract.
///         Concrete contracts only need to declare their own EIP-712 name/version
///         (passed to the EIP712 constructor) and implement their specific logic.
abstract contract MztkEscrowBase is IEscrowBase, Ownable, EIP712 {
    // ─── Deadline bounds (shared across all escrows) ──────────────────────────

    /// @dev Minimum allowed escrow deadline: 1 day (prevents gaming with tiny windows).
    uint48 public constant MIN_DEADLINE_DURATION = 1 days;
    /// @dev Maximum allowed escrow deadline: 365 days.
    uint48 public constant MAX_DEADLINE_DURATION = 365 days;

    // ─── Signature validity bounds ────────────────────────────────────────────

    /// @dev Minimum server-signature validity window: 1 minute.
    uint48 public constant MIN_SIG_VALIDITY_DURATION = 1 minutes;
    /// @dev Maximum server-signature validity window: 1 hour.
    uint48 public constant MAX_SIG_VALIDITY_DURATION = 1 hours;

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Trusted backend server address; all user-action signatures must
    ///         be signed by this key (enforces blacklist / authorization checks).
    address public signer;

    /// @notice Duration from position creation to escrow expiry (default 30 days).
    uint48 public defaultDeadlineDuration = 30 days;

    /// @notice Window after `signedAt` within which a server signature is valid (default 15 min).
    uint48 public sigValidityDuration = 15 minutes;

    /// @notice ERC-20 tokens accepted by this escrow.
    mapping(address => bool) public isSupportedToken;

    /// @notice Addresses authorized to call relayer-gated functions.
    mapping(address => bool) public isRelayer;

    // ─── Constructor ──────────────────────────────────────────────────────────

    /// @param initialOwner   Ownable owner (multisig / deployer).
    /// @param initialSigner  Backend server key; must be non-zero.
    /// @param eip712Name     EIP-712 domain name for the concrete contract.
    /// @param eip712Version  EIP-712 domain version for the concrete contract.
    constructor(address initialOwner, address initialSigner, string memory eip712Name, string memory eip712Version)
        Ownable(initialOwner)
        EIP712(eip712Name, eip712Version)
    {
        if (initialSigner == address(0)) revert InvalidAddress();
        signer = initialSigner;
        emit SignerUpdated(initialSigner);
    }

    // ─── Modifier ─────────────────────────────────────────────────────────────

    modifier onlyRelayerOrOwner() {
        if (!isRelayer[msg.sender] && msg.sender != owner()) revert OnlyRelayerOrOwner();
        _;
    }

    // ─── Admin: signer ────────────────────────────────────────────────────────

    /// @inheritdoc IEscrowBase
    function setSigner(address newSigner) external override onlyOwner {
        if (newSigner == address(0)) revert InvalidAddress();
        signer = newSigner;
        emit SignerUpdated(newSigner);
    }

    // ─── Admin: token whitelist ───────────────────────────────────────────────

    /// @inheritdoc IEscrowBase
    function updateTokenSupport(address token, bool isSupported) external override onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        isSupportedToken[token] = isSupported;
        emit TokenSupportUpdated(token, isSupported);
    }

    // ─── Admin: relayer ACL ───────────────────────────────────────────────────

    /// @inheritdoc IEscrowBase
    function updateRelayer(address relayer, bool isAuthorized) external override onlyOwner {
        if (relayer == address(0)) revert InvalidAddress();
        isRelayer[relayer] = isAuthorized;
        emit RelayerUpdated(relayer, isAuthorized);
    }

    // ─── Admin: deadline duration ─────────────────────────────────────────────

    /// @inheritdoc IEscrowBase
    function updateDefaultDeadlineDuration(uint48 newDuration) external override onlyOwner {
        if (newDuration < MIN_DEADLINE_DURATION || newDuration > MAX_DEADLINE_DURATION) {
            revert InvalidDeadline();
        }
        defaultDeadlineDuration = newDuration;
        emit DefaultDeadlineDurationUpdated(newDuration);
    }

    // ─── Admin: sig validity window ───────────────────────────────────────────

    /// @inheritdoc IEscrowBase
    function updateSigValidityDuration(uint48 newDuration) external override onlyOwner {
        if (newDuration < MIN_SIG_VALIDITY_DURATION || newDuration > MAX_SIG_VALIDITY_DURATION) {
            revert InvalidDeadline();
        }
        sigValidityDuration = newDuration;
        emit SigValidityDurationUpdated(newDuration);
    }

    // ─── Internal: server-signature verification ──────────────────────────────

    /// @notice Verifies a server-issued EIP-712 signature.
    /// @dev    Rules (checked in order):
    ///           1. `signedAt` must not be in the future → revert `InvalidSignature`.
    ///              (Prevents pre-signing with future timestamps to extend validity windows.)
    ///           2. `block.timestamp <= signedAt + sigValidityDuration` → revert `SignatureExpired`.
    ///              (Signature has gone stale beyond the allowed window.)
    ///           3. Recovered address must equal `signer` → revert `InvalidSignature`.
    ///              (Ensures only the trusted backend key can authorize operations.)
    ///         Note: rules 1 and 3 share `InvalidSignature`; rule 2 uses `SignatureExpired`.
    /// @param structHash  keccak256(abi.encode(TYPEHASH, ...fields...)) — caller constructs this.
    /// @param signedAt    Unix timestamp embedded in the struct hash when the server signed.
    /// @param signature   65-byte ECDSA signature.
    function _verifyServerSig(bytes32 structHash, uint256 signedAt, bytes calldata signature) internal view {
        if (signedAt > block.timestamp) revert InvalidSignature();
        if (block.timestamp > signedAt + sigValidityDuration) revert SignatureExpired();
        if (ECDSA.recover(_hashTypedDataV4(structHash), signature) != signer) revert InvalidSignature();
    }
}
