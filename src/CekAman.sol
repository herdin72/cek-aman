// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal view interface of the SPACE ID Agent ID registry on BNB Smart Chain
///         (HandleRegistry, 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F).
///         Agent IDs are soulbound, one per address and cannot be burned, so
///         `balanceOf(x) > 0` is a permanent "this address is an Agent ID holder" check.
interface IAgentID {
    function balanceOf(address owner) external view returns (uint256);
    function handleOf(address owner) external view returns (string memory);
}

/// @title  Cek Aman — Agent Claim Check
/// @notice Community safety reports for free-claim / mint contracts, written only by Agent ID holders.
///
///         * One Agent ID = one report per target contract (it can be changed or withdrawn at any time).
///         * "Proof of claim": when a report is filed, the contract asks the target for
///           `balanceOf(reporter)`. If the reporter actually holds the claimed token/NFT, the
///           report is marked as proof-backed and counted separately.
///         * Every first-time reporter receives one free, soulbound "Guardian" badge (ERC-721 + ERC-5192).
///
///         Safety properties: no owner, no admin, no upgrades, no payable functions, holds no
///         funds, never moves tokens and never asks for approvals. The only external calls are
///         read-only: the Agent ID registry, and a gas-capped `balanceOf` staticcall on the target.
contract CekAman {
    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint8 public constant SAFE = 1;
    uint8 public constant SCAM = 2;

    /// Reason codes. 0 = no reason given (allowed for both verdicts).
    /// SAFE reasons: 1..3, SCAM reasons: 4..8.
    uint8 public constant REASON_GAS_ONLY_WORKED = 1;
    uint8 public constant REASON_RECEIVED_ASSET = 2;
    uint8 public constant REASON_VERIFIED_NO_OWNER_RISK = 3;
    uint8 public constant REASON_HIDDEN_FEE = 4;
    uint8 public constant REASON_ASKED_APPROVAL = 5;
    uint8 public constant REASON_REVERTED_GAS_LOST = 6;
    uint8 public constant REASON_FAKE_BRANDING = 7;
    uint8 public constant REASON_NOTHING_RECEIVED = 8;

    /// Status values returned by `statusOf`.
    uint8 public constant STATUS_NONE = 0;
    uint8 public constant STATUS_SAFE = 1;
    uint8 public constant STATUS_SCAM = 2;
    uint8 public constant STATUS_MIXED = 3;

    /// Gas forwarded to the target's `balanceOf` during the proof-of-claim check.
    uint256 public constant PROOF_GAS = 30_000;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IAgentID public immutable agentId;

    struct Report {
        uint8 verdict; // 0 = none, 1 = SAFE, 2 = SCAM
        uint8 reason;
        bool proof; // reporter held the target's token/NFT when reporting
        uint40 updatedAt;
    }

    struct Tally {
        uint32 safe;
        uint32 scam;
        uint32 proofSafe;
        uint32 proofScam;
        uint40 firstReportAt;
        uint40 lastReportAt;
    }

    /// target => reporter => report
    mapping(address => mapping(address => Report)) public reportOf;
    mapping(address => Tally) internal _tally;
    address[] internal _targets;

    /// reporter => number of active reports
    mapping(address => uint32) public activeReportsBy;
    /// number of active reports across all targets
    uint256 public totalReports;

    // Guardian badge (soulbound ERC-721)
    string public constant name = "Cek Aman Guardian";
    string public constant symbol = "GUARD";
    uint256 public totalGuardians;
    /// holder => badge tokenId (0 = no badge)
    mapping(address => uint256) public guardianOf;
    mapping(uint256 => address) internal _badgeOwner;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event Reported(address indexed target, address indexed reporter, uint8 verdict, uint8 reason, bool proof);
    event ReportWithdrawn(address indexed target, address indexed reporter);
    event TargetListed(address indexed target, uint256 index);

    // ERC-721 / ERC-5192
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event Locked(uint256 tokenId);

    error NotAgentIdHolder();
    error InvalidTarget();
    error InvalidVerdict();
    error InvalidReason();
    error NoReport();
    error Soulbound();
    error NonexistentToken();
    error ZeroAddress();

    constructor(IAgentID registry) {
        if (address(registry) == address(0)) revert ZeroAddress();
        agentId = registry;
    }

    // ---------------------------------------------------------------------
    // Reporting
    // ---------------------------------------------------------------------

    /// @notice File (or change) your report on a contract.
    /// @param target  The free-claim / mint contract on this chain. Must be a contract, not a wallet.
    /// @param verdict 1 = SAFE, 2 = SCAM.
    /// @param reason  0 = none, SAFE: 1..3, SCAM: 4..8 (see constants / `reasonLabel`).
    function report(address target, uint8 verdict, uint8 reason) external {
        if (agentId.balanceOf(msg.sender) == 0) revert NotAgentIdHolder();
        if (target.code.length == 0 || target == address(this) || target == address(agentId)) {
            revert InvalidTarget();
        }
        if (verdict != SAFE && verdict != SCAM) revert InvalidVerdict();
        if (reason != 0) {
            if (verdict == SAFE ? reason > 3 : (reason < 4 || reason > 8)) revert InvalidReason();
        }

        bool proof = _holdsTarget(target, msg.sender);

        Tally storage t = _tally[target];
        Report storage r = reportOf[target][msg.sender];
        uint40 nowTs = uint40(block.timestamp);

        if (t.firstReportAt == 0) {
            t.firstReportAt = nowTs;
            _targets.push(target);
            emit TargetListed(target, _targets.length - 1);
        }

        if (r.verdict != 0) {
            _subtract(t, r.verdict, r.proof);
        } else {
            activeReportsBy[msg.sender] += 1;
            totalReports += 1;
        }
        _add(t, verdict, proof);
        t.lastReportAt = nowTs;

        r.verdict = verdict;
        r.reason = reason;
        r.proof = proof;
        r.updatedAt = nowTs;

        if (guardianOf[msg.sender] == 0) _mintBadge(msg.sender);

        emit Reported(target, msg.sender, verdict, reason, proof);
    }

    /// @notice Withdraw your own report on a contract. The Guardian badge stays.
    function withdraw(address target) external {
        Report storage r = reportOf[target][msg.sender];
        if (r.verdict == 0) revert NoReport();
        Tally storage t = _tally[target];
        _subtract(t, r.verdict, r.proof);
        t.lastReportAt = uint40(block.timestamp);
        activeReportsBy[msg.sender] -= 1;
        totalReports -= 1;
        delete reportOf[target][msg.sender];
        emit ReportWithdrawn(target, msg.sender);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function isAgent(address account) external view returns (bool) {
        return agentId.balanceOf(account) > 0;
    }

    /// @notice 0 = no reports, 1 = SAFE majority, 2 = SCAM majority, 3 = MIXED (tie).
    function statusOf(address target) public view returns (uint8) {
        Tally memory t = _tally[target];
        if (t.safe == 0 && t.scam == 0) return STATUS_NONE;
        if (t.scam > t.safe) return STATUS_SCAM;
        if (t.safe > t.scam) return STATUS_SAFE;
        return STATUS_MIXED;
    }

    function getTally(address target)
        external
        view
        returns (
            uint32 safe,
            uint32 scam,
            uint32 proofSafe,
            uint32 proofScam,
            uint8 status,
            uint40 firstReportAt,
            uint40 lastReportAt
        )
    {
        Tally memory t = _tally[target];
        return (t.safe, t.scam, t.proofSafe, t.proofScam, statusOf(target), t.firstReportAt, t.lastReportAt);
    }

    function targetsCount() external view returns (uint256) {
        return _targets.length;
    }

    function targetAt(uint256 index) external view returns (address) {
        return _targets[index];
    }

    /// @notice Most recently listed targets, newest first (at most `count`).
    function getRecent(uint256 count) external view returns (address[] memory list) {
        uint256 n = _targets.length;
        if (count > n) count = n;
        list = new address[](count);
        for (uint256 i; i < count; ++i) {
            list[i] = _targets[n - 1 - i];
        }
    }

    /// @notice Targets in listing order, from `offset`, at most `limit`.
    function getPage(uint256 offset, uint256 limit) external view returns (address[] memory list) {
        uint256 n = _targets.length;
        if (offset >= n) return new address[](0);
        uint256 end = limit > n - offset ? n : offset + limit;
        list = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            list[i - offset] = _targets[i];
        }
    }

    function reasonLabel(uint8 reason) public pure returns (string memory) {
        if (reason == 0) return "No reason given";
        if (reason == 1) return "Claimed, gas only, it worked";
        if (reason == 2) return "Received the token/NFT";
        if (reason == 3) return "Verified source, no risky owner powers";
        if (reason == 4) return "Hidden fee / not actually free";
        if (reason == 5) return "Asked for token approval";
        if (reason == 6) return "Reverted, gas lost";
        if (reason == 7) return "Fake or impersonating brand";
        if (reason == 8) return "Nothing received";
        return "Unknown";
    }

    // ---------------------------------------------------------------------
    // Guardian badge — soulbound ERC-721 (ERC-5192)
    // ---------------------------------------------------------------------

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC-165
            || interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f // ERC-721 Metadata
            || interfaceId == 0xb45a3c0e; // ERC-5192
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return guardianOf[owner] == 0 ? 0 : 1;
    }

    function ownerOf(uint256 tokenId) public view returns (address owner) {
        owner = _badgeOwner[tokenId];
        if (owner == address(0)) revert NonexistentToken();
    }

    function locked(uint256 tokenId) external view returns (bool) {
        ownerOf(tokenId);
        return true;
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        ownerOf(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        address owner = ownerOf(tokenId);
        string memory handle = _safeHandle(owner);
        string memory idStr = _toString(tokenId);
        string memory reports = _toString(activeReportsBy[owner]);
        string memory label = bytes(handle).length == 0 ? "Agent ID holder" : string.concat(handle, ".ai");

        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">',
            '<rect width="400" height="400" rx="32" fill="#0b1f17"/>',
            '<path d="M200 60l110 40v80c0 70-48 120-110 150C138 300 90 250 90 180v-80z" fill="#12a36b" stroke="#c8f7dc" stroke-width="6"/>',
            '<path d="M150 190l35 35 70-75" fill="none" stroke="#fff" stroke-width="18" stroke-linecap="round" stroke-linejoin="round"/>',
            '<text x="200" y="352" font-family="monospace" font-size="22" fill="#c8f7dc" text-anchor="middle">GUARDIAN #',
            idStr,
            "</text>",
            '<text x="200" y="382" font-family="monospace" font-size="16" fill="#8fd3b0" text-anchor="middle">',
            label,
            " | reports: ",
            reports,
            "</text></svg>"
        );

        string memory json = string.concat(
            '{"name":"Cek Aman Guardian #',
            idStr,
            '","description":"Soulbound badge for Agent ID holders who report free-claim contracts on Cek Aman (Agent Claim Check). Not transferable, no monetary value.",',
            '"attributes":[{"trait_type":"Agent ID","value":"',
            label,
            '"},{"trait_type":"Active reports","display_type":"number","value":',
            reports,
            '}],"image":"data:image/svg+xml;base64,',
            _base64(bytes(svg)),
            '"}'
        );
        return string.concat("data:application/json;base64,", _base64(bytes(json)));
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _add(Tally storage t, uint8 verdict, bool proof) private {
        if (verdict == SAFE) {
            t.safe += 1;
            if (proof) t.proofSafe += 1;
        } else {
            t.scam += 1;
            if (proof) t.proofScam += 1;
        }
    }

    function _subtract(Tally storage t, uint8 verdict, bool proof) private {
        if (verdict == SAFE) {
            t.safe -= 1;
            if (proof) t.proofSafe -= 1;
        } else {
            t.scam -= 1;
            if (proof) t.proofScam -= 1;
        }
    }

    function _mintBadge(address to) private {
        uint256 id = ++totalGuardians;
        guardianOf[to] = id;
        _badgeOwner[id] = to;
        emit Transfer(address(0), to, id);
        emit Locked(id);
    }

    /// Gas-capped, read-only `balanceOf(who)` on the target. Copies at most 32 bytes of return
    /// data, so a malicious target can neither change state nor return-bomb the caller.
    function _holdsTarget(address target, address who) private view returns (bool) {
        bool ok;
        uint256 size;
        uint256 bal;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, shl(224, 0x70a08231))
            mstore(add(ptr, 4), who)
            ok := staticcall(PROOF_GAS, target, ptr, 36, 0, 32)
            size := returndatasize()
            bal := mload(0)
        }
        return ok && size >= 32 && bal > 0;
    }

    /// Handle from the registry, keeping only [a-z0-9] (the registry already enforces this).
    function _safeHandle(address owner) private view returns (string memory) {
        try agentId.handleOf(owner) returns (string memory h) {
            bytes memory b = bytes(h);
            if (b.length > 64) return "";
            for (uint256 i; i < b.length; ++i) {
                bytes1 c = b[i];
                if (!((c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39))) return "";
            }
            return h;
        } catch {
            return "";
        }
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    bytes private constant _B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function _base64(bytes memory data) private pure returns (string memory) {
        if (data.length == 0) return "";
        bytes memory table = _B64;
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        bytes memory result = new bytes(encodedLen);
        uint256 j;
        for (uint256 i; i < data.length; i += 3) {
            uint256 a = uint8(data[i]);
            uint256 b = i + 1 < data.length ? uint8(data[i + 1]) : 0;
            uint256 c = i + 2 < data.length ? uint8(data[i + 2]) : 0;
            uint256 triple = (a << 16) | (b << 8) | c;
            result[j++] = table[(triple >> 18) & 63];
            result[j++] = table[(triple >> 12) & 63];
            result[j++] = i + 1 < data.length ? table[(triple >> 6) & 63] : bytes1("=");
            result[j++] = i + 2 < data.length ? table[triple & 63] : bytes1("=");
        }
        return string(result);
    }
}
