// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Drives the token with random call sequences from a small set of actors (the deployer,
/// which starts with the whole supply, plus ordinary holders) and with arbitrary fuzzed
/// recipients, keeping ghost accounting of every balance and allowance it expects.
/// @dev Every handler either succeeds and asserts its exact postcondition, or deliberately
/// drives an input past a bound and asserts the exact revert. The handler itself never reverts,
/// so the suite runs with `fail-on-revert` and an unexpected revert is a failure, not a skip.
contract RobobetHandler is CommonBase, StdAssertions, StdCheats, StdUtils {
    uint256 public constant SUPPLY = 1_000_000_000 ether;

    RobobetToken public immutable token;
    address public immutable deployer;

    /// @dev Fixed actors: the deployer first, then ordinary holders. All transfers between them.
    address[] public actors;
    /// @dev Every address that has ever held or been sent tokens (actors plus fuzzed strangers).
    address[] public touched;
    mapping(address => bool) public isTouched;

    // Ghost accounting: what the token must report after the same sequence.
    mapping(address => uint256) public ghostBalance;
    mapping(address => uint256) public ghostSent;
    mapping(address => uint256) public ghostReceived;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    // Coverage counters so a vacuous run (every handler short-circuiting) is visible.
    uint256 public transfers;
    uint256 public transfersFrom;
    uint256 public approvals;
    uint256 public expectedReverts;
    uint256 public strangerTransfers;

    constructor(RobobetToken token_, address deployer_, address[] memory holders) {
        token = token_;
        deployer = deployer_;
        actors.push(deployer_);
        _touch(deployer_);
        ghostBalance[deployer_] = SUPPLY;
        for (uint256 i; i < holders.length; ++i) {
            actors.push(holders[i]);
            _touch(holders[i]);
        }
    }

    // ------------------------------------------------------------------
    // Views for the invariants
    // ------------------------------------------------------------------

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function initialBalance(address who) public view returns (uint256) {
        return who == deployer ? SUPPLY : 0;
    }

    // ------------------------------------------------------------------
    // Successful paths (bounded so the call must succeed)
    // ------------------------------------------------------------------

    /// @notice An actor sends part of its balance (possibly zero, possibly all) to another actor.
    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
        transfers++;
    }

    /// @notice An actor sends to an arbitrary address the fuzzer picked, which is then tracked.
    function transferToStranger(uint256 fromSeed, address to, uint256 amount) external {
        address from = _actor(fromSeed);
        if (to == address(0) || to == address(token)) {
            to = address(uint160(uint256(keccak256(abi.encode(to, touched.length)))));
        }
        _touch(to);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
        strangerTransfers++;
    }

    /// @notice A stranger that received tokens sends some of them back into the actor set.
    function strangerSendsBack(uint256 strangerSeed, uint256 toSeed, uint256 amount) external {
        address from = touched[bound(strangerSeed, 0, touched.length - 1)];
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _transfer(from, to, amount);
        transfers++;
    }

    /// @notice An actor sets an allowance to any value, including zero and the infinite sentinel.
    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Make the infinite allowance reachable often enough to matter.
        if (amount % 7 == 0) amount = type(uint256).max;
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        ghostAllowance[owner][spender] = amount;
        assertEq(token.allowance(owner, spender), amount, "allowance not set");
        approvals++;
    }

    /// @notice A spender moves tokens within both the owner's balance and its allowance.
    function transferFrom(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);

        uint256 fromBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");

        if (allowed != type(uint256).max) {
            ghostAllowance[owner][spender] = allowed - amount;
        }
        assertEq(token.allowance(owner, spender), ghostAllowance[owner][spender], "allowance after transferFrom");
        _applyMove(owner, to, amount, fromBefore, toBefore);
        transfersFrom++;
    }

    // ------------------------------------------------------------------
    // Failure paths (driven past a bound; the exact revert is asserted and state must not move)
    // ------------------------------------------------------------------

    /// @notice A transfer of more than the sender holds reverts with the exact error and moves nothing.
    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 held = token.balanceOf(from);
        amount = bound(amount, held + 1, type(uint256).max);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(from);
        try token.transfer(to, amount) {
            revert("transfer above balance succeeded");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, from, held, amount));
        }
        assertEq(token.balanceOf(from), held, "failed transfer changed the sender");
        assertEq(token.balanceOf(to), toBefore, "failed transfer changed the receiver");
        expectedReverts++;
    }

    /// @notice A transferFrom beyond the (finite) allowance reverts and leaves balances and allowance alone.
    function transferFromAboveAllowance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount)
        external
    {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        if (allowed == type(uint256).max) {
            // Infinite allowance can never be exceeded; pin it to a finite value first.
            allowed = bound(amount, 0, SUPPLY);
            vm.prank(owner);
            token.approve(spender, allowed);
            ghostAllowance[owner][spender] = allowed;
            approvals++;
        }
        amount = bound(amount, allowed + 1, type(uint256).max);
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom above allowance succeeded");
        } catch (bytes memory err) {
            assertEq(
                err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientAllowance.selector, spender, allowed, amount)
            );
        }
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom changed the allowance");
        assertEq(token.balanceOf(owner), ownerBefore, "failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed the receiver");
        expectedReverts++;
    }

    /// @notice An allowance larger than the owner's balance does not let the spender move more than the balance.
    function transferFromAboveBalance(uint256 spenderSeed, uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address owner = _actor(ownerSeed);
        address to = _recipient(toSeed);
        uint256 held = token.balanceOf(owner);
        amount = bound(amount, held + 1, SUPPLY + 1);
        // Give the spender a sufficient, finite allowance so the balance check is what fires.
        uint256 allowed = bound(amount, amount, SUPPLY + 1);
        vm.prank(owner);
        token.approve(spender, allowed);
        ghostAllowance[owner][spender] = allowed;
        approvals++;
        uint256 toBefore = token.balanceOf(to);

        vm.prank(spender);
        try token.transferFrom(owner, to, amount) {
            revert("transferFrom above balance succeeded");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, owner, held, amount));
        }
        // The balance check comes after the allowance spend, so the revert must have undone the spend.
        assertEq(token.allowance(owner, spender), allowed, "failed transferFrom spent the allowance");
        assertEq(token.balanceOf(owner), held, "failed transferFrom changed the owner");
        assertEq(token.balanceOf(to), toBefore, "failed transferFrom changed the receiver");
        expectedReverts++;
    }

    /// @notice Nobody can send to the zero address, by either path.
    function sendToZeroAddress(uint256 fromSeed, uint256 amount, bool viaTransferFrom) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        bytes memory expected = abi.encodeWithSelector(RobobetToken.ERC20InvalidReceiver.selector, address(0));
        if (viaTransferFrom) {
            vm.prank(from);
            token.approve(from, amount);
            ghostAllowance[from][from] = amount;
            approvals++;
            vm.prank(from);
            try token.transferFrom(from, address(0), amount) {
                revert("transferFrom to zero succeeded");
            } catch (bytes memory err) {
                assertEq(err, expected);
            }
            assertEq(token.allowance(from, from), amount, "a reverted transferFrom spent the allowance");
        } else {
            vm.prank(from);
            try token.transfer(address(0), amount) {
                revert("transfer to zero succeeded");
            } catch (bytes memory err) {
                assertEq(err, expected);
            }
        }
        assertEq(token.balanceOf(address(0)), 0);
        expectedReverts++;
    }

    /// @notice Approving the zero spender reverts and records nothing.
    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        vm.prank(owner);
        try token.approve(address(0), amount) {
            revert("approve of the zero spender succeeded");
        } catch (bytes memory err) {
            assertEq(err, abi.encodeWithSelector(RobobetToken.ERC20InvalidSpender.selector, address(0)));
        }
        assertEq(token.allowance(owner, address(0)), 0);
        expectedReverts++;
    }

    /// @notice The token accepts no ether and answers no selector it does not define.
    function sendEtherOrGarbage(uint256 fromSeed, uint256 value, bytes4 selector) external {
        address from = _actor(fromSeed);
        value = bound(value, 1, 100 ether);
        vm.deal(from, value);
        vm.prank(from);
        (bool ok,) = address(token).call{value: value}("");
        assertFalse(ok, "the token accepted ether");
        if (
            selector != RobobetToken.transfer.selector && selector != RobobetToken.approve.selector
                && selector != RobobetToken.transferFrom.selector
        ) {
            vm.prank(from);
            (ok,) = address(token).call(abi.encodeWithSelector(selector, from, type(uint256).max));
            // Views answer; anything else must revert. Either way nothing may move (checked by invariants).
            if (ok) {
                bool isView = selector == RobobetToken.balanceOf.selector || selector == RobobetToken.allowance.selector
                    || selector == RobobetToken.totalSupply.selector || selector == bytes4(keccak256("name()"))
                    || selector == bytes4(keccak256("symbol()")) || selector == bytes4(keccak256("decimals()"))
                    || selector == bytes4(keccak256("TOTAL_SUPPLY()"));
                assertTrue(isView, "an undefined selector did not revert");
            }
        }
        expectedReverts++;
    }

    /// @notice A common admin entry point, called by the deployer (the most plausible trusted party)
    /// and by a stranger, is not there: it must revert and move nothing.
    function adminCall(uint256 which, uint256 callerSeed) external {
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "lock(address)",
            "seize(address)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setFee(uint256)"
        ];
        string memory sig = signatures[bound(which, 0, signatures.length - 1)];
        address caller = callerSeed % 2 == 0 ? deployer : _actor(callerSeed);
        vm.prank(caller);
        (bool ok,) = address(token).call(abi.encodeWithSignature(sig, caller, type(uint128).max));
        assertFalse(ok, sig);
        expectedReverts++;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    /// @dev Recipients come from the whole touched set so strangers can receive more than once.
    function _recipient(uint256 seed) internal view returns (address) {
        return touched[bound(seed, 0, touched.length - 1)];
    }

    function _touch(address who) internal {
        if (!isTouched[who]) {
            isTouched[who] = true;
            touched.push(who);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal {
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        _applyMove(from, to, amount, fromBefore, toBefore);
    }

    function _applyMove(address from, address to, uint256 amount, uint256 fromBefore, uint256 toBefore) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        if (from == to) {
            assertEq(token.balanceOf(from), fromBefore, "self-transfer changed the balance");
        } else {
            assertEq(token.balanceOf(from), fromBefore - amount, "sender did not lose exactly the amount");
            assertEq(token.balanceOf(to), toBefore + amount, "receiver did not gain exactly the amount");
        }
    }
}

/// @notice Invariants over random call sequences driven by `RobobetHandler`.
/// @dev The token holds value for everyone from the moment it is deployed: the whole supply sits
/// on the deployer and then spreads. What must never change: the supply, the fact that the supply
/// is exactly the sum of balances, that every balance and allowance is exactly what the sequence
/// of successful calls implies, and that the contract never holds ether.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract RobobetTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    RobobetToken token;
    RobobetHandler handler;
    address constant DEPLOYER = address(0xFAC7);

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new RobobetToken();

        address[] memory holders = new address[](5);
        holders[0] = address(0xA11CE);
        holders[1] = address(0xB0B);
        holders[2] = address(0xCA201);
        holders[3] = address(0xD15);
        holders[4] = address(0xE4E);
        handler = new RobobetHandler(token, DEPLOYER, holders);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](12);
        selectors[0] = RobobetHandler.transfer.selector;
        selectors[1] = RobobetHandler.transferToStranger.selector;
        selectors[2] = RobobetHandler.strangerSendsBack.selector;
        selectors[3] = RobobetHandler.approve.selector;
        selectors[4] = RobobetHandler.transferFrom.selector;
        selectors[5] = RobobetHandler.transferAboveBalance.selector;
        selectors[6] = RobobetHandler.transferFromAboveAllowance.selector;
        selectors[7] = RobobetHandler.transferFromAboveBalance.selector;
        selectors[8] = RobobetHandler.sendToZeroAddress.selector;
        selectors[9] = RobobetHandler.approveZeroSpender.selector;
        selectors[10] = RobobetHandler.sendEtherOrGarbage.selector;
        selectors[11] = RobobetHandler.adminCall.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev A fixed supply never changes, from anyone, through any sequence.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "the supply changed");
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// @dev What the token reports as held, over every address that was ever sent anything, is the supply:
    /// nothing is created, nothing is lost, nothing leaks to an untracked address.
    function invariant_balancesSumToSupply() public view {
        uint256 n = handler.touchedCount();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY, "the balances do not sum to the supply");
    }

    /// @dev Every balance is exactly what the successful calls imply (internal accounting == external reality).
    function invariant_balancesMatchGhostAccounting() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.touched(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "balance drifted from the ghost");
        }
    }

    /// @dev Nobody ends with more than they started with plus what they received, less what they sent.
    function invariant_netFlowAccounting() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.touched(i);
            uint256 expected = handler.initialBalance(who) + handler.ghostReceived(who) - handler.ghostSent(who);
            assertEq(token.balanceOf(who), expected, "balance disagrees with the flow ledger");
            assertLe(token.balanceOf(who), SUPPLY, "a balance exceeds the supply");
        }
    }

    /// @dev Allowances are exactly what approve and the finite spends imply; an infinite one stays infinite.
    function invariant_allowancesMatchGhostAccounting() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev The zero address can never hold anything, and the token never holds ether.
    function invariant_zeroAddressAndTokenHoldNothing() public view {
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev Nobody but a holder can reach a holder's balance: the deployer, the plausible trusted party,
    /// has no allowance it did not get from the holder, so it cannot pull.
    function invariant_deployerCannotPullWithoutAllowance() public {
        uint256 n = handler.actorCount();
        for (uint256 i = 1; i < n; ++i) {
            address holder = handler.actors(i);
            if (token.allowance(holder, DEPLOYER) != 0) continue;
            uint256 held = token.balanceOf(holder);
            if (held == 0) continue;
            vm.prank(DEPLOYER);
            (bool ok,) = address(token).call(abi.encodeCall(RobobetToken.transferFrom, (holder, DEPLOYER, 1)));
            assertFalse(ok, "the deployer pulled a holder's tokens without an allowance");
            assertEq(token.balanceOf(holder), held);
        }
    }

    /// @dev Metadata cannot be changed by any sequence (there is no setter; this pins it so a future
    /// edit that adds one is caught).
    function invariant_metadataIsFixed() public view {
        assertEq(token.name(), "robobet");
        assertEq(token.symbol(), "ROBOBET");
        assertEq(token.decimals(), 18);
    }
}

/// @notice The token targeted directly, with no handler: forge picks random senders, random
/// selectors and raw arguments. Most calls revert (and are allowed to); the properties that must
/// still hold are the ones that need no ghost: the supply, the zero address and ether.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = false
contract RobobetTokenRawInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    RobobetToken token;
    address constant DEPLOYER = address(0xFAC7);
    address constant HOLDER = address(0x401D);
    uint256 constant HOLDER_START = SUPPLY / 1_000;

    function setUp() public {
        vm.prank(DEPLOYER);
        token = new RobobetToken();
        vm.prank(DEPLOYER);
        token.transfer(HOLDER, HOLDER_START);
        targetContract(address(token));
        // Random senders include arbitrary addresses, the deployer and the holder; none is privileged.
        targetSender(DEPLOYER);
        targetSender(address(0xBEEF));
        targetSender(address(0xCAFE));
        // The holder itself never acts, so its balance may only grow.
        excludeSender(HOLDER);
    }

    function invariant_rawSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
    }

    function invariant_rawZeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(address(token).balance, 0);
    }

    /// @dev A holder that never signs anything can only ever gain: no caller, the deployer included,
    /// can reduce it (no allowance was given, no admin call exists).
    function invariant_rawPassiveHolderNeverLoses() public view {
        assertGe(token.balanceOf(HOLDER), HOLDER_START, "a passive holder lost tokens");
    }

    /// @dev The deployer never holds more than it started with: there is nothing to mint back into it.
    function invariant_rawDeployerNeverExceedsInitialSupplyShare() public view {
        assertLe(token.balanceOf(DEPLOYER), SUPPLY - HOLDER_START, "the deployer gained tokens from nowhere");
    }
}
