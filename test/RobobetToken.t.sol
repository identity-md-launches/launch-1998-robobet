// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Stands in for the ProjectFactory: deploys the token with CREATE2 from its creation
/// code, exactly as the launch does, so the supply lands on this contract and not on the test.
contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0) && deployed.code.length > 0, "constructor failed");
    }

    function move(RobobetToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }
}

contract RobobetTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    FactoryProbe factory;
    RobobetToken token;

    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);

    function setUp() public {
        factory = new FactoryProbe();
        token = RobobetToken(factory.deploy(type(RobobetToken).creationCode, bytes32(uint256(1))));
    }

    // ------------------------------------------------------------------
    // Metadata and supply
    // ------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "robobet");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 10 ** 18);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.balanceOf(address(this)), 0, "the test harness must not receive anything");
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        RobobetToken fresh = new RobobetToken();
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
    }

    function test_constructorTakesNoArgumentsAndNeedsNoOtherContract() public {
        // A fresh deployer on a chain with nothing else on it: the constructor must still succeed.
        FactoryProbe lonely = new FactoryProbe();
        address deployed = lonely.deploy(type(RobobetToken).creationCode, bytes32(uint256(42)));
        assertEq(RobobetToken(deployed).balanceOf(address(lonely)), SUPPLY);
    }

    // ------------------------------------------------------------------
    // transfer
    // ------------------------------------------------------------------

    function test_transferMovesExactAmountAndEmits() public {
        factory.move(token, ALICE, 1_000 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, BOB, 400 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 400 ether));
        assertEq(token.balanceOf(ALICE), 600 ether);
        assertEq(token.balanceOf(BOB), 400 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, 10 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        factory.move(token, ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, 5 ether, 6 ether));
        token.transfer(BOB, 6 ether);
        assertEq(token.balanceOf(ALICE), 5 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferRevertsToZeroAddress() public {
        factory.move(token, ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
    }

    // ------------------------------------------------------------------
    // approve / transferFrom
    // ------------------------------------------------------------------

    function test_approveSetsAllowanceAndEmits() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, BOB, 7 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(BOB, 7 ether));
        assertEq(token.allowance(ALICE, BOB), 7 ether);
        // approve overwrites rather than adds.
        vm.prank(ALICE);
        token.approve(BOB, 2 ether);
        assertEq(token.allowance(ALICE, BOB), 2 ether);
    }

    function test_approveRevertsForZeroSpender() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceAndEmits() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 30 ether);

        vm.expectEmit(true, true, true, true);
        emit Approval(ALICE, BOB, 10 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(ALICE, CAROL, 20 ether);
        vm.prank(BOB);
        assertTrue(token.transferFrom(ALICE, CAROL, 20 ether));

        assertEq(token.balanceOf(ALICE), 80 ether);
        assertEq(token.balanceOf(CAROL), 20 ether);
        assertEq(token.allowance(ALICE, BOB), 10 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, 30 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, BOB, 30 ether, 31 ether)
        );
        token.transferFrom(ALICE, CAROL, 31 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.allowance(ALICE, BOB), 30 ether);
    }

    function test_transferFromWithoutAnyAllowanceReverts() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, BOB, 0, 1));
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_transferFromRevertsOnInsufficientBalanceEvenWithAllowance() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transferFrom(ALICE, CAROL, 11 ether);
        // The failed call must not have touched the allowance.
        assertEq(token.allowance(ALICE, BOB), 100 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(BOB, type(uint256).max);
        vm.prank(BOB);
        token.transferFrom(ALICE, CAROL, 60 ether);
        assertEq(token.allowance(ALICE, BOB), type(uint256).max);
        assertEq(token.balanceOf(CAROL), 60 ether);
    }

    function test_transferFromRevertsToZeroAddress() public {
        factory.move(token, ALICE, 10 ether);
        vm.prank(ALICE);
        token.approve(BOB, 10 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(ALICE, address(0), 1 ether);
    }

    // ------------------------------------------------------------------
    // Fuzz: conservation and exactness
    // ------------------------------------------------------------------

    function testFuzz_transferConservesSupplyAndMovesExactly(address to, uint256 seedAmount, uint256 amount) public {
        vm.assume(to != address(0) && to != ALICE);
        seedAmount = bound(seedAmount, 0, SUPPLY);
        amount = bound(amount, 0, seedAmount);
        factory.move(token, ALICE, seedAmount);

        vm.prank(ALICE);
        assertTrue(token.transfer(to, amount));

        assertEq(token.balanceOf(ALICE), seedAmount - amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(to) + token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceAlwaysReverts(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY - 1);
        amount = bound(amount, held + 1, SUPPLY);
        factory.move(token, ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, ALICE, held, amount));
        token.transfer(BOB, amount);
    }

    function testFuzz_transferFromNeverExceedsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY - 1);
        amount = bound(amount, allowed + 1, SUPPLY);
        factory.move(token, ALICE, SUPPLY);
        vm.prank(ALICE);
        token.approve(BOB, allowed);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, BOB, allowed, amount));
        token.transferFrom(ALICE, CAROL, amount);
    }

    // ------------------------------------------------------------------
    // No admin surface: nothing mints, pauses, freezes or seizes
    // ------------------------------------------------------------------

    function test_noCallIncreasesSupplyOrMintsToCaller() public {
        address attacker = address(0xBEEF);
        string[10] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "unpause()",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(address(factory));
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
            assertEq(token.balanceOf(attacker), 0, signatures[i]);
        }
    }

    function test_noPrivilegedCallMovesOrFreezesAHolder() public {
        factory.move(token, ALICE, SUPPLY / 1_000);
        uint256 held = token.balanceOf(ALICE);
        string[12] memory signatures = [
            "pause()",
            "blacklist(address)",
            "blocklist(address)",
            "freeze(address)",
            "freezeAccount(address)",
            "setBlacklist(address,bool)",
            "setBlocked(address,bool)",
            "lock(address)",
            "disableTransfers()",
            "setTransfersEnabled(bool)",
            "burnFrom(address,uint256)",
            "seize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, true));
            assertFalse(ok, signatures[i]);
        }
        // The deployer holds no allowance from the holder, so it cannot pull either.
        vm.prank(address(factory));
        vm.expectRevert(
            abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), held);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, held / 2));
        assertEq(token.balanceOf(BOB), held / 2);
    }

    function test_unknownSelectorAndPlainEtherReverts() public {
        (bool ok,) = address(token).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok);
        (ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "the token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    // ------------------------------------------------------------------
    // Bytecode properties the launch floor requires
    // ------------------------------------------------------------------

    function test_runtimeCodeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_creationCodeIsDeterministicForTheLaunch() public pure {
        // The launch deploys from the bytecode as built; without constructor arguments, the
        // creation code is the whole input and must be non-empty.
        assertGt(type(RobobetToken).creationCode.length, 0);
    }
}
