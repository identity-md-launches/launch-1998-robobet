// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Inputs the implementation did not necessarily consider: zero, one wei, the whole supply,
/// the maximum, the same call twice, the zero address as a caller, a spender who is the owner, and
/// the boundary of the infinite allowance. Read as an adversary of `RobobetToken`.
/// forge-config: default.fuzz.runs = 1000
contract RobobetTokenEdgesTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant MAX = type(uint256).max;

    address constant DEPLOYER = address(0xFAC7);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    RobobetToken token;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new RobobetToken();
    }

    function _give(address to, uint256 amount) internal {
        vm.prank(DEPLOYER);
        token.transfer(to, amount);
    }

    // ------------------------------------------------------------------
    // Supply boundaries
    // ------------------------------------------------------------------

    function test_wholeSupplyMovesInOneTransfer() public {
        _give(ALICE, SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        // And the former holder is now a nobody: one wei more is a revert with the exact numbers.
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, DEPLOYER, 0, 1));
        token.transfer(ALICE, 1);
    }

    function test_oneWeiMovesExactly() public {
        _give(ALICE, 1);
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY - 1);
        vm.prank(ALICE);
        token.transfer(BOB, 1);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
    }

    function test_supplyPlusOneAndMaxUintRevertWithExactError() public {
        vm.prank(DEPLOYER);
        vm.expectRevert(
            abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
        vm.prank(DEPLOYER);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, DEPLOYER, SUPPLY, MAX));
        token.transfer(ALICE, MAX);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_receivingCannotOverflowBecauseSupplyIsBounded() public {
        // Everything on one account, then more on top is impossible: the unchecked add is safe only
        // because no path can mint. Pin that the sum of all balances is the supply after a full sweep.
        _give(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.transfer(BOB, SUPPLY);
        vm.prank(BOB);
        token.transfer(ALICE, SUPPLY);
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEPLOYER), 0);
    }

    function test_emptyAccountCanTransferZeroButNotOne() public {
        assertEq(token.balanceOf(ALICE), 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    // ------------------------------------------------------------------
    // The zero address as a caller (reachable on chain only in theory, but the branches exist)
    // ------------------------------------------------------------------

    function test_zeroAddressCannotSend() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidSender.selector, address(0)));
        token.transfer(ALICE, 0);
    }

    function test_zeroAddressCannotApprove() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidApprover.selector, address(0)));
        token.approve(ALICE, 1);
    }

    function test_transferFromTheZeroAddressRevertsEvenForZeroValue() public {
        // The zero address has no allowance, but a zero value passes the allowance check; the
        // sender check must still refuse it.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidSender.selector, address(0)));
        token.transferFrom(address(0), ALICE, 0);
    }

    function test_transferFromTheZeroAddressWithValueFailsOnAllowanceFirst() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(0), ALICE, 1);
    }

    // ------------------------------------------------------------------
    // Allowance edges
    // ------------------------------------------------------------------

    function test_transferFromZeroWithoutAllowanceSucceedsAndEmitsApprovalOfZero() public {
        // value 0 never exceeds an allowance of 0. The implementation emits Approval on every
        // finite spend, including this no-op one; the event is informational and is pinned here.
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, BOB, 0);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, CAROL, 0);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 0));
    }

    function test_allowanceOfMaxMinusOneIsFiniteAndDecrements() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, MAX - 1);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 3 ether);
        assertEq(token.allowance(ALICE, BOB), MAX - 1 - 3 ether, "max-1 must be a finite allowance");
    }

    function test_infiniteAllowanceSurvivesRepeatedSpendsAndEmitsNoApproval() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, MAX);
        for (uint256 i; i < 5; ++i) {
            vm.recordLogs();
            vm.prank(BOB);
            token.transferFrom(ALICE, CAROL, 1 ether);
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(logs.length, 1, "an infinite spend must emit only Transfer");
            assertEq(logs[0].topics[0], Transfer.selector);
        }
        assertEq(token.allowance(ALICE, BOB), MAX);
        assertEq(token.balanceOf(CAROL), 5 ether);
    }

    function test_spendingExactAllowanceLeavesZeroAndThenOneWeiReverts() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 4 ether);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 4 ether);
        assertEq(token.allowance(ALICE, BOB), 0);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_sameApproveTwiceIsIdempotent() public {
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        vm.prank(ALICE);
        token.approve(BOB, 5 ether);
        assertEq(token.allowance(ALICE, BOB), 5 ether);
        // Resetting to zero is the standard front-running mitigation and must work.
        vm.prank(ALICE);
        token.approve(BOB, 0);
        assertEq(token.allowance(ALICE, BOB), 0);
    }

    function test_allowanceIsDirectional() public {
        _give(BOB, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        // Alice allowed Bob, not the other way round: Alice cannot spend Bob's tokens.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(BOB, ALICE, 1);
        assertEq(token.allowance(BOB, ALICE), 0);
    }

    function test_allowanceIsPerSpenderNotShared() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, CAROL, 0, 1));
        token.transferFrom(ALICE, CAROL, 1);
    }

    function test_ownerAsItsOwnSpenderStillNeedsAndSpendsAnAllowance() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, ALICE, 0, 1 ether));
        token.transferFrom(ALICE, BOB, 1 ether);

        vm.prank(ALICE);
        token.approve(ALICE, 3 ether);
        vm.prank(ALICE);
        token.transferFrom(ALICE, BOB, 1 ether);
        assertEq(token.allowance(ALICE, ALICE), 2 ether);
        assertEq(token.balanceOf(BOB), 1 ether);
    }

    function test_transferFromToTheOwnerKeepsBalanceButSpendsAllowance() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        token.transferFrom(ALICE, ALICE, 4 ether);
        assertEq(token.balanceOf(ALICE), 10 ether, "a self-destined transferFrom changed the balance");
        assertEq(token.allowance(ALICE, BOB), 6 ether, "a self-destined transferFrom did not spend the allowance");
    }

    function test_allowanceDoesNotGrantMoreThanTheBalanceAsItShrinks() public {
        _give(ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        // Alice spends most of it herself; Bob's allowance is now larger than what remains.
        vm.prank(ALICE);
        token.transfer(CAROL, 8 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, 2 ether, 3 ether));
        token.transferFrom(ALICE, CAROL, 3 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether, "the failed pull spent the allowance");
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 2 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.allowance(ALICE, BOB), 8 ether);
    }

    // ------------------------------------------------------------------
    // Return data and call surface
    // ------------------------------------------------------------------

    function test_mutatorsReturnAbiEncodedTrue() public {
        _give(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(RobobetToken.transfer, (BOB, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));
        vm.prank(ALICE);
        (ok, ret) = address(token).call(abi.encodeCall(RobobetToken.approve, (BOB, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));
        vm.prank(BOB);
        (ok, ret) = address(token).call(abi.encodeCall(RobobetToken.transferFrom, (ALICE, CAROL, 1)));
        assertTrue(ok);
        assertEq(ret, abi.encode(true));
    }

    function test_noBurnOrMintSelectorExists() public {
        string[6] memory signatures = [
            "burn(uint256)",
            "burn(address,uint256)",
            "burnFrom(address,uint256)",
            "mint(address,uint256)",
            "increaseAllowance(address,uint256)",
            "decreaseAllowance(address,uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], DEPLOYER, 1));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(DEPLOYER), SUPPLY);
    }

    function test_constructorMintsToWhoeverDeploysNotToAFixedAddress() public {
        // Two deployments from two deployers: each deployer gets its own full supply, and neither
        // token knows about the other. There is no hard-coded beneficiary.
        vm.prank(ALICE);
        RobobetToken a = new RobobetToken();
        vm.prank(BOB);
        RobobetToken b = new RobobetToken();
        assertEq(a.balanceOf(ALICE), SUPPLY);
        assertEq(a.balanceOf(BOB), 0);
        assertEq(b.balanceOf(BOB), SUPPLY);
        assertEq(b.balanceOf(ALICE), 0);
        assertEq(a.balanceOf(DEPLOYER), 0);
    }

    // ------------------------------------------------------------------
    // Fuzz: raw inputs, with success-or-exact-revert as the property
    // ------------------------------------------------------------------

    /// @dev Any transfer either moves exactly `amount` or reverts with exactly one documented error
    /// and changes nothing. There is no third outcome (partial move, silent failure, fee).
    function testFuzz_transferSucceedsExactlyOrRevertsExactly(uint256 held, address to, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        _give(ALICE, held);
        uint256 toBefore = token.balanceOf(to);
        uint256 deployerBefore = token.balanceOf(DEPLOYER);

        vm.prank(ALICE);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok);
            assertTrue(to != address(0), "a transfer to the zero address succeeded");
            assertLe(amount, held, "a transfer above the balance succeeded");
            if (to == ALICE) {
                assertEq(token.balanceOf(ALICE), held);
            } else {
                assertEq(token.balanceOf(ALICE), held - amount);
                assertEq(token.balanceOf(to), toBefore + amount);
            }
        } catch (bytes memory err) {
            if (to == address(0)) {
                assertEq(err, abi.encodeWithSelector(RobobetToken.ERC20InvalidReceiver.selector, address(0)));
            } else {
                assertGt(amount, held, "a transfer within the balance reverted");
                assertEq(
                    err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, held, amount)
                );
            }
            assertEq(token.balanceOf(ALICE), held);
            assertEq(token.balanceOf(to), toBefore);
        }
        if (to != DEPLOYER) assertEq(token.balanceOf(DEPLOYER), deployerBefore);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Same property for transferFrom over the full cross product of balance, allowance and amount,
    /// including the infinite allowance; the allowance only ever changes by exactly the spent amount.
    function testFuzz_transferFromSucceedsExactlyOrRevertsExactly(uint256 held, uint256 allowed, uint256 amount)
        public
    {
        held = bound(held, 0, SUPPLY);
        _give(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowed);

        vm.prank(BOB);
        try token.transferFrom(ALICE, CAROL, amount) returns (bool ok) {
            assertTrue(ok);
            assertLe(amount, held);
            assertTrue(allowed == MAX || amount <= allowed);
            assertEq(token.balanceOf(ALICE), held - amount);
            assertEq(token.balanceOf(CAROL), amount);
            assertEq(token.allowance(ALICE, BOB), allowed == MAX ? MAX : allowed - amount);
        } catch (bytes memory err) {
            if (allowed != MAX && amount > allowed) {
                assertEq(
                    err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, BOB, allowed, amount)
                );
            } else {
                assertGt(amount, held);
                assertEq(
                    err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, held, amount)
                );
            }
            assertEq(token.balanceOf(ALICE), held);
            assertEq(token.balanceOf(CAROL), 0);
            assertEq(token.allowance(ALICE, BOB), allowed, "a failed transferFrom changed the allowance");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev A round trip restores both balances exactly: no fee, no rounding, no reflection.
    function testFuzz_roundTripRestoresBalances(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, 0, held);
        _give(ALICE, held);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        vm.prank(BOB);
        token.transfer(ALICE, amount);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
    }

    /// @dev Splitting a transfer into two legs or sending it in one moves the same total.
    function testFuzz_transferIsAdditive(uint256 held, uint256 first, uint256 second) public {
        held = bound(held, 0, SUPPLY);
        first = bound(first, 0, held);
        second = bound(second, 0, held - first);
        _give(ALICE, held);
        vm.startPrank(ALICE);
        token.transfer(BOB, first);
        token.transfer(BOB, second);
        vm.stopPrank();
        assertEq(token.balanceOf(BOB), first + second);
        assertEq(token.balanceOf(ALICE), held - first - second);
    }

    /// @dev approve is a pure overwrite: the last value wins whatever came before.
    function testFuzz_approveOverwrites(uint256 a, uint256 b) public {
        vm.startPrank(ALICE);
        token.approve(BOB, a);
        assertEq(token.allowance(ALICE, BOB), a);
        token.approve(BOB, b);
        assertEq(token.allowance(ALICE, BOB), b);
        vm.stopPrank();
        // And it touched nobody else's allowance.
        assertEq(token.allowance(BOB, ALICE), 0);
        assertEq(token.allowance(ALICE, CAROL), 0);
    }

    /// @dev Any sequence of finite spends decrements the allowance by exactly the sum spent.
    function testFuzz_finiteAllowanceDecrementsBySpentSum(uint256 allowed, uint256 a, uint256 b) public {
        allowed = bound(allowed, 0, SUPPLY);
        a = bound(a, 0, allowed);
        b = bound(b, 0, allowed - a);
        _give(ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(BOB, allowed);
        vm.startPrank(BOB);
        token.transferFrom(ALICE, CAROL, a);
        token.transferFrom(ALICE, CAROL, b);
        vm.stopPrank();
        assertEq(token.allowance(ALICE, BOB), allowed - a - b);
        assertEq(token.balanceOf(CAROL), a + b);
    }

    /// @dev balanceOf and allowance are pure reads: calling them changes nothing and they never revert
    /// for any address, including zero and the token itself.
    function testFuzz_viewsNeverRevert(address a, address b) public view {
        token.balanceOf(a);
        token.allowance(a, b);
        token.allowance(b, a);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }
}
