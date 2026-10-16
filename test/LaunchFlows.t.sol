// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice A stand-in for a Uniswap v4 PoolManager and an ordinary trader: both just hold and
/// move the token with plain ERC-20 calls. The point is that every flow the launch performs,
/// as well as a trader's buy and sell, moves exactly what it says, with no fee and no block.
contract Holder {
    function send(RobobetToken token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function pull(RobobetToken token, address from, uint256 amount) external returns (bool) {
        return token.transferFrom(from, address(this), amount);
    }

    function allow(RobobetToken token, address spender, uint256 amount) external {
        token.approve(spender, amount);
    }
}

/// @notice The launch's economics (job values, see README) rehearsed with plain transfers.
contract LaunchFlowsTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1_000; // 10%, fixed by the factory
    uint256 constant POOL_BPS = 5_000; // economics.poolBps
    address constant REMAINDER_TO = 0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66; // economics.remainderTo
    address constant CLAIMANT_A = address(0xC1A1);
    address constant CLAIMANT_B = address(0xC1A2);

    Holder factory;
    Holder distributor;
    Holder poolManager;
    Holder trader;
    RobobetToken token;

    function setUp() public {
        factory = new Holder();
        distributor = new Holder();
        poolManager = new Holder();
        trader = new Holder();
        vm.prank(address(factory));
        token = new RobobetToken();
    }

    function test_factoryHoldsTheWholeSupplyAtDeployment() public view {
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_swarmShareArrivesWholeAndClaimsArriveWhole() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        assertTrue(factory.send(token, address(distributor), swarm));
        assertEq(token.balanceOf(address(distributor)), swarm, "the swarm's share arrived short");

        uint256 half = swarm / 2;
        assertTrue(distributor.send(token, CLAIMANT_A, half));
        assertTrue(distributor.send(token, CLAIMANT_B, swarm - half));
        assertEq(token.balanceOf(CLAIMANT_A), half);
        assertEq(token.balanceOf(CLAIMANT_B), swarm - half);
        assertEq(token.balanceOf(address(distributor)), 0, "the distributor kept something back");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_fullLaunchSplitLeavesNothingBehindAndChangesNoSupply() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        assertTrue(factory.send(token, address(distributor), swarm));
        assertTrue(factory.send(token, address(poolManager), pool));
        assertTrue(factory.send(token, REMAINDER_TO, remainder));

        assertEq(token.balanceOf(address(distributor)), swarm);
        assertEq(token.balanceOf(address(poolManager)), pool);
        assertEq(token.balanceOf(REMAINDER_TO), remainder);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(swarm + pool + remainder, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_poolManagerCanPullTheSeedThroughAnAllowance() public {
        // The v4 seed settles by the factory sending (or the manager pulling) the exact amount.
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        factory.allow(token, address(poolManager), pool);
        assertTrue(poolManager.pull(token, address(factory), pool));
        assertEq(token.balanceOf(address(poolManager)), pool);
        assertEq(token.allowance(address(factory), address(poolManager)), 0);
    }

    function test_traderCanBuyAndSellBackExactly() public {
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        factory.send(token, address(poolManager), pool);

        // Buy: the pool pays the trader out of its reserve.
        uint256 bought = 12_345 ether;
        assertTrue(poolManager.send(token, address(trader), bought));
        assertEq(token.balanceOf(address(trader)), bought);

        // Sell: the trader settles the full amount back into the pool.
        assertTrue(trader.send(token, address(poolManager), bought));
        assertEq(token.balanceOf(address(trader)), 0, "a trader could not sell everything back");
        assertEq(token.balanceOf(address(poolManager)), pool, "the pool did not get back what it paid out");
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_factoryCannotSendMoreThanTheSupply() public {
        vm.expectRevert(
            abi.encodeWithSelector(RobobetToken.ERC20InsufficientBalance.selector, address(factory), SUPPLY, SUPPLY + 1)
        );
        factory.send(token, address(distributor), SUPPLY + 1);
    }

    function testFuzz_anySplitOfTheSupplyIsConserved(uint16 swarmBps, uint16 poolBps) public {
        swarmBps = uint16(bound(swarmBps, 0, 10_000));
        poolBps = uint16(bound(poolBps, 0, 10_000 - swarmBps));
        uint256 swarm = (SUPPLY * swarmBps) / 10_000;
        uint256 pool = (SUPPLY * poolBps) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;
        factory.send(token, address(distributor), swarm);
        factory.send(token, address(poolManager), pool);
        factory.send(token, REMAINDER_TO, remainder);
        assertEq(
            token.balanceOf(address(distributor)) + token.balanceOf(address(poolManager))
                + token.balanceOf(REMAINDER_TO) + token.balanceOf(address(factory)),
            SUPPLY
        );
        assertEq(token.totalSupply(), SUPPLY);
    }
}
