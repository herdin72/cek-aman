// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CekAman, IAgentID} from "../src/CekAman.sol";

contract MockAgentID is IAgentID {
    mapping(address => string) internal _handle;

    function give(address who, string memory h) external {
        _handle[who] = h;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return bytes(_handle[owner]).length > 0 ? 1 : 0;
    }

    function handleOf(address owner) external view returns (string memory) {
        return _handle[owner];
    }
}

/// A "free claim" token: anyone can claim once.
contract MockClaimToken {
    mapping(address => uint256) public balanceOf;

    function claim() external {
        balanceOf[msg.sender] += 1000;
    }
}

contract NoBalanceOf {
    uint256 public x;
}

contract RevertingBalanceOf {
    function balanceOf(address) external pure returns (uint256) {
        revert("nope");
    }
}

contract GasBurner {
    function balanceOf(address) external view returns (uint256) {
        uint256 i;
        while (gasleft() > 100) {
            i++;
        }
        return i;
    }
}

contract ReturnBomb {
    fallback() external {
        assembly {
            return(0, 20000)
        }
    }
}

contract ShortReturn {
    fallback() external {
        assembly {
            mstore(0, 1)
            return(0, 16)
        }
    }
}

contract CekAmanTest is Test {
    CekAman internal ca;
    MockAgentID internal reg;
    MockClaimToken internal tok;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory"); // no Agent ID

    function setUp() public {
        reg = new MockAgentID();
        ca = new CekAman(reg);
        tok = new MockClaimToken();
        reg.give(alice, "alice");
        reg.give(bob, "bob42");
        reg.give(carol, "carol");
    }

    // ------------------------------------------------------------ access

    function test_ConstructorRejectsZeroRegistry() public {
        vm.expectRevert(CekAman.ZeroAddress.selector);
        new CekAman(IAgentID(address(0)));
    }

    function test_NonHolderCannotReport() public {
        vm.prank(mallory);
        vm.expectRevert(CekAman.NotAgentIdHolder.selector);
        ca.report(address(tok), 1, 0);
    }

    function test_IsAgent() public view {
        assertTrue(ca.isAgent(alice));
        assertFalse(ca.isAgent(mallory));
    }

    function test_RejectsWalletTargets() public {
        vm.prank(alice);
        vm.expectRevert(CekAman.InvalidTarget.selector);
        ca.report(bob, 2, 0); // an EOA — Cek Aman is not a tool for rating people's wallets
    }

    function test_RejectsSelfAndRegistryTargets() public {
        vm.startPrank(alice);
        vm.expectRevert(CekAman.InvalidTarget.selector);
        ca.report(address(ca), 1, 0);
        vm.expectRevert(CekAman.InvalidTarget.selector);
        ca.report(address(reg), 1, 0);
        vm.stopPrank();
    }

    function test_RejectsBadVerdictAndReason() public {
        vm.startPrank(alice);
        vm.expectRevert(CekAman.InvalidVerdict.selector);
        ca.report(address(tok), 0, 0);
        vm.expectRevert(CekAman.InvalidVerdict.selector);
        ca.report(address(tok), 3, 0);
        vm.expectRevert(CekAman.InvalidReason.selector);
        ca.report(address(tok), 1, 4); // scam reason on a SAFE verdict
        vm.expectRevert(CekAman.InvalidReason.selector);
        ca.report(address(tok), 2, 3); // safe reason on a SCAM verdict
        vm.expectRevert(CekAman.InvalidReason.selector);
        ca.report(address(tok), 2, 9);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ tallies

    function test_ReportCountsAndMintsBadge() public {
        vm.prank(alice);
        vm.expectEmit(true, true, false, true, address(ca));
        emit CekAman.Reported(address(tok), alice, 1, 1, false);
        ca.report(address(tok), 1, 1);

        (uint32 s, uint32 sc, uint32 ps, uint32 psc, uint8 st,,) = ca.getTally(address(tok));
        assertEq(s, 1);
        assertEq(sc, 0);
        assertEq(ps, 0);
        assertEq(psc, 0);
        assertEq(st, 1);
        assertEq(ca.targetsCount(), 1);
        assertEq(ca.totalReports(), 1);
        assertEq(ca.activeReportsBy(alice), 1);
        assertEq(ca.guardianOf(alice), 1);
        assertEq(ca.ownerOf(1), alice);
        assertEq(ca.balanceOf(alice), 1);
        assertEq(ca.totalGuardians(), 1);
    }

    function test_OneReportPerAgentPerTarget_RepeatIsUpdateNotDoubleCount() public {
        vm.startPrank(alice);
        ca.report(address(tok), 1, 0);
        ca.report(address(tok), 1, 0);
        ca.report(address(tok), 1, 2);
        vm.stopPrank();
        (uint32 s, uint32 sc,,,,,) = ca.getTally(address(tok));
        assertEq(s, 1);
        assertEq(sc, 0);
        assertEq(ca.totalReports(), 1);
        assertEq(ca.targetsCount(), 1);
        assertEq(ca.totalGuardians(), 1); // no second badge
    }

    function test_ChangeVote() public {
        vm.startPrank(alice);
        ca.report(address(tok), 1, 0);
        ca.report(address(tok), 2, 4);
        vm.stopPrank();
        (uint32 s, uint32 sc,,, uint8 st,,) = ca.getTally(address(tok));
        assertEq(s, 0);
        assertEq(sc, 1);
        assertEq(st, 2);
        (uint8 v, uint8 r,,) = ca.reportOf(address(tok), alice);
        assertEq(v, 2);
        assertEq(r, 4);
    }

    function test_StatusMajorityAndTie() public {
        vm.prank(alice);
        ca.report(address(tok), 1, 0);
        vm.prank(bob);
        ca.report(address(tok), 2, 0);
        assertEq(ca.statusOf(address(tok)), 3); // MIXED
        vm.prank(carol);
        ca.report(address(tok), 2, 8);
        assertEq(ca.statusOf(address(tok)), 2); // SCAM
        assertEq(ca.statusOf(address(0xBEEF)), 0); // never reported
    }

    function test_Withdraw() public {
        vm.startPrank(alice);
        ca.report(address(tok), 2, 5);
        ca.withdraw(address(tok));
        vm.expectRevert(CekAman.NoReport.selector);
        ca.withdraw(address(tok));
        vm.stopPrank();
        (uint32 s, uint32 sc,,, uint8 st,,) = ca.getTally(address(tok));
        assertEq(s + sc, 0);
        assertEq(st, 0);
        assertEq(ca.totalReports(), 0);
        assertEq(ca.activeReportsBy(alice), 0);
        assertEq(ca.guardianOf(alice), 1); // badge stays
        // reporting again does not re-list the target
        vm.prank(alice);
        ca.report(address(tok), 1, 0);
        assertEq(ca.targetsCount(), 1);
    }

    function test_CannotWithdrawSomeoneElsesReport() public {
        vm.prank(alice);
        ca.report(address(tok), 2, 0);
        vm.prank(bob);
        vm.expectRevert(CekAman.NoReport.selector);
        ca.withdraw(address(tok));
        (, uint32 sc,,,,,) = ca.getTally(address(tok));
        assertEq(sc, 1);
    }

    // ------------------------------------------------------------ proof of claim

    function test_ProofOfClaim() public {
        vm.prank(alice);
        tok.claim();
        vm.prank(alice);
        ca.report(address(tok), 1, 2);
        vm.prank(bob); // never claimed
        ca.report(address(tok), 1, 0);
        (uint32 s,, uint32 ps,,,,) = ca.getTally(address(tok));
        assertEq(s, 2);
        assertEq(ps, 1);
        (,, bool proofA,) = ca.reportOf(address(tok), alice);
        (,, bool proofB,) = ca.reportOf(address(tok), bob);
        assertTrue(proofA);
        assertFalse(proofB);
    }

    function test_ProofFlagUpdatesOnChange() public {
        vm.prank(alice);
        ca.report(address(tok), 2, 0); // no proof yet
        vm.prank(alice);
        tok.claim();
        vm.prank(alice);
        ca.report(address(tok), 1, 1); // now with proof
        (uint32 s, uint32 sc, uint32 ps, uint32 psc,,,) = ca.getTally(address(tok));
        assertEq(s, 1);
        assertEq(sc, 0);
        assertEq(ps, 1);
        assertEq(psc, 0);
    }

    function test_HostileTargetsCannotBreakReporting() public {
        address[5] memory hostile = [
            address(new NoBalanceOf()),
            address(new RevertingBalanceOf()),
            address(new GasBurner()),
            address(new ReturnBomb()),
            address(new ShortReturn())
        ];
        for (uint256 i; i < hostile.length; ++i) {
            vm.prank(alice);
            uint256 g = gasleft();
            ca.report(hostile[i], 2, 0);
            uint256 used = g - gasleft();
            assertLt(used, 400_000, "report gas bounded");
            (,, bool proof,) = ca.reportOf(hostile[i], alice);
            if (i == 3) {
                // ReturnBomb returns 20000 zero bytes => balance 0 => no proof
                assertFalse(proof);
            } else {
                assertFalse(proof);
            }
        }
        assertEq(ca.targetsCount(), 5);
    }

    // ------------------------------------------------------------ lists

    function test_RecentAndPage() public {
        address[] memory ts = new address[](4);
        for (uint256 i; i < 4; ++i) {
            ts[i] = address(new MockClaimToken());
            vm.prank(alice);
            ca.report(ts[i], 1, 0);
        }
        address[] memory recent = ca.getRecent(3);
        assertEq(recent.length, 3);
        assertEq(recent[0], ts[3]);
        assertEq(recent[2], ts[1]);
        assertEq(ca.getRecent(99).length, 4);

        address[] memory page = ca.getPage(1, 2);
        assertEq(page.length, 2);
        assertEq(page[0], ts[1]);
        assertEq(page[1], ts[2]);
        assertEq(ca.getPage(3, 10).length, 1);
        assertEq(ca.getPage(10, 10).length, 0);
        assertEq(ca.getPage(1, type(uint256).max).length, 3);
        assertEq(ca.targetAt(0), ts[0]);
        assertEq(ca.activeReportsBy(alice), 4);
    }

    // ------------------------------------------------------------ badge

    function test_BadgeIsSoulbound() public {
        vm.prank(alice);
        ca.report(address(tok), 1, 0);
        vm.startPrank(alice);
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.transferFrom(alice, bob, 1);
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.safeTransferFrom(alice, bob, 1);
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.safeTransferFrom(alice, bob, 1, "");
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.approve(bob, 1);
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.setApprovalForAll(bob, true);
        vm.stopPrank();
        assertTrue(ca.locked(1));
        assertEq(ca.getApproved(1), address(0));
        assertFalse(ca.isApprovedForAll(alice, bob));
        assertEq(ca.ownerOf(1), alice);
    }

    function test_BadgeInterfacesAndErrors() public {
        assertTrue(ca.supportsInterface(0x01ffc9a7));
        assertTrue(ca.supportsInterface(0x80ac58cd));
        assertTrue(ca.supportsInterface(0x5b5e139f));
        assertTrue(ca.supportsInterface(0xb45a3c0e));
        assertFalse(ca.supportsInterface(0xffffffff));
        vm.expectRevert(CekAman.NonexistentToken.selector);
        ca.ownerOf(1);
        vm.expectRevert(CekAman.NonexistentToken.selector);
        ca.tokenURI(1);
        vm.expectRevert(CekAman.ZeroAddress.selector);
        ca.balanceOf(address(0));
        assertEq(ca.balanceOf(mallory), 0);
        assertEq(ca.name(), "Cek Aman Guardian");
        assertEq(ca.symbol(), "GUARD");
    }

    function test_TokenURI() public {
        vm.prank(bob);
        ca.report(address(tok), 2, 7);
        string memory uri = ca.tokenURI(1);
        assertTrue(_startsWith(uri, "data:application/json;base64,"));
        assertGt(bytes(uri).length, 500);
    }

    function test_SequentialBadgeIds() public {
        vm.prank(alice);
        ca.report(address(tok), 1, 0);
        vm.prank(bob);
        ca.report(address(tok), 1, 0);
        assertEq(ca.guardianOf(alice), 1);
        assertEq(ca.guardianOf(bob), 2);
        assertEq(ca.ownerOf(2), bob);
    }

    function test_ReasonLabels() public view {
        assertEq(ca.reasonLabel(4), "Hidden fee / not actually free");
        assertEq(ca.reasonLabel(99), "Unknown");
    }

    // ------------------------------------------------------------ fuzz / invariant-ish

    function testFuzz_TallyMatchesReports(uint8[12] memory actions) public {
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < actions.length; ++i) {
            address w = who[actions[i] % 3];
            uint8 op = (actions[i] / 3) % 3; // 0 safe, 1 scam, 2 withdraw
            if (op == 2) {
                (uint8 v,,,) = ca.reportOf(address(tok), w);
                if (v == 0) continue;
                vm.prank(w);
                ca.withdraw(address(tok));
            } else {
                vm.prank(w);
                ca.report(address(tok), op + 1, 0);
            }
        }
        uint32 safe;
        uint32 scam;
        for (uint256 k; k < 3; ++k) {
            (uint8 v,,,) = ca.reportOf(address(tok), who[k]);
            if (v == 1) safe++;
            if (v == 2) scam++;
        }
        (uint32 s, uint32 sc,,,,,) = ca.getTally(address(tok));
        assertEq(s, safe);
        assertEq(sc, scam);
        assertEq(ca.totalReports(), safe + scam);
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
