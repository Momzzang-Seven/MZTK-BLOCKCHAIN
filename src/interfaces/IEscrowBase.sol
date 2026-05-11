// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

/// @notice Common admin interface shared by all MZTK escrow contracts.
///         Extracts the token whitelist, relayer ACL, server-signer, and
///         escrow-deadline management that are duplicated across escrows.
interface IEscrowBase {
    // ─── Events ───────────────────────────────────────────────────────────────

    /// @dev Emitted when the trusted server-signer address changes.
    event SignerUpdated(address indexed newSigner);
    /// @dev Emitted when a token's whitelist status changes.
    event TokenSupportUpdated(address indexed token, bool isSupported);
    /// @dev Emitted when a relayer's authorization status changes.
    event RelayerUpdated(address indexed relayer, bool isAuthorized);
    /// @dev Emitted when defaultDeadlineDuration is updated.
    event DefaultDeadlineDurationUpdated(uint48 newDuration);
    /// @dev Emitted when sigValidityDuration is updated.
    event SigValidityDurationUpdated(uint48 newDuration);

    // ─── Errors ───────────────────────────────────────────────────────────────

    /// @dev Zero address supplied where a non-zero address is required.
    error InvalidAddress();
    /// @dev Deadline duration out of [MIN_DEADLINE_DURATION, MAX_DEADLINE_DURATION].
    error InvalidDeadline();
    /// @dev Token is not on the supported whitelist.
    error UnsupportedToken();
    /// @dev Caller is neither a relayer nor the owner.
    error OnlyRelayerOrOwner();
    /// @dev Server signature is structurally invalid or signed by the wrong key.
    error InvalidSignature();
    /// @dev signedAt + sigValidityDuration < block.timestamp (signature stale).
    error SignatureExpired();

    // ─── Admin functions ──────────────────────────────────────────────────────

    /// @notice Replace the trusted server-signer address (owner only).
    function setSigner(address newSigner) external;

    /// @notice Whitelist or de-list an ERC-20 token (owner only).
    function updateTokenSupport(address token, bool isSupported) external;

    /// @notice Authorize or revoke a relayer address (owner only).
    function updateRelayer(address relayer, bool isAuthorized) external;

    /// @notice Update the escrow deadline applied to new positions (owner only).
    function updateDefaultDeadlineDuration(uint48 newDuration) external;

    /// @notice Update the server-signature validity window (owner only).
    function updateSigValidityDuration(uint48 newDuration) external;
}
