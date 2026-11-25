// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {CekAman, IAgentID} from "../src/CekAman.sol";

/// Fork tests against the real SPACE ID Agent ID registry on BNB Smart Chain.
/// Run: forge test --match-contract CekAmanForkTest --fork-url https://bsc-dataseed.bnbchain.org
contract CekAmanForkTest is Test {
    IAgentID internal constant REGISTRY = IAgentID(0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F);
    // A real Agent ID holder (aibou.ai) who also holds a DUNE Keys NFT.
    address internal constant HOLDER = 0x8E78ade1b0B56D7b149A4209258a7D84aeeA5EBd;
    // Real free-claim contracts on BSC used as report targets.
    address internal constant DUNE_KEYS = 0x1296da72914EA99a6Ac0D0c94Afba2D890dFA25b; // ERC-721, HOLDER owns one
    address internal constant ROLL_CALL = 0x99D419890a9aa9F8BAd54473D9942Edd7a30e130; // no balanceOf
    address internal constant NON_HOLDER = 0x000000000000000000000000000000000000dEaD;

    CekAman internal ca;

    function setUp() public {
        if (block.chainid != 56) {
            vm.createSelectFork("https://bsc-dataseed.bnbchain.org");
        }
        ca = new CekAman(REGISTRY);
    }

    function test_Fork_RegistryFacts() public view {
        assertGt(REGISTRY.balanceOf(HOLDER), 0);
        assertEq(REGISTRY.balanceOf(NON_HOLDER), 0);
        assertEq(REGISTRY.handleOf(HOLDER), "aibou");
        assertTrue(ca.isAgent(HOLDER));
        assertFalse(ca.isAgent(NON_HOLDER));
    }

    function test_Fork_HolderReportsWithProofOfClaim() public {
        vm.prank(HOLDER);
        ca.report(DUNE_KEYS, 1, 2);
        (uint32 s,, uint32 ps,, uint8 st,,) = ca.getTally(DUNE_KEYS);
        assertEq(s, 1);
        assertEq(ps, 1, "holder owns a DUNE Keys NFT -> proof-backed");
        assertEq(st, 1);
        assertEq(ca.guardianOf(HOLDER), 1);
    }

    function test_Fork_TargetWithoutBalanceOf() public {
        vm.prank(HOLDER);
        ca.report(ROLL_CALL, 1, 1);
        (,, bool proof,) = ca.reportOf(ROLL_CALL, HOLDER);
        assertFalse(proof);
    }

    function test_Fork_NonHolderRejected() public {
        vm.prank(NON_HOLDER);
        vm.expectRevert(CekAman.NotAgentIdHolder.selector);
        ca.report(DUNE_KEYS, 2, 4);
    }

    function test_Fork_DoubleVoteAndChange() public {
        vm.startPrank(HOLDER);
        ca.report(DUNE_KEYS, 1, 0);
        ca.report(DUNE_KEYS, 1, 0);
        ca.report(DUNE_KEYS, 2, 4);
        vm.stopPrank();
        (uint32 s, uint32 sc,, uint32 psc,,,) = ca.getTally(DUNE_KEYS);
        assertEq(s, 0);
        assertEq(sc, 1);
        assertEq(psc, 1);
        assertEq(ca.totalReports(), 1);
        assertEq(ca.totalGuardians(), 1);
    }

    function test_Fork_BadgeSoulboundAndShowsHandle() public {
        vm.prank(HOLDER);
        ca.report(DUNE_KEYS, 1, 2);
        vm.prank(HOLDER);
        vm.expectRevert(CekAman.Soulbound.selector);
        ca.transferFrom(HOLDER, NON_HOLDER, 1);
        string memory uri = ca.tokenURI(1);
        assertGt(bytes(uri).length, 500);
        emit log_string(uri);
    }

    function test_Fork_GasCosts() public {
        vm.prank(HOLDER);
        uint256 g = gasleft();
        ca.report(DUNE_KEYS, 1, 2);
        emit log_named_uint("first report (incl. badge mint) gas", g - gasleft());
        vm.prank(HOLDER);
        g = gasleft();
        ca.report(ROLL_CALL, 1, 1);
        emit log_named_uint("second report gas", g - gasleft());
    }
}
