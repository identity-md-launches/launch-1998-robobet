// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRobobetToken} from "../script/Deploy.s.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice The deployment function is called directly, with no environment and no broadcast.
contract DeployTest is Test {
    function test_deployMintsTheSupplyToTheScriptCaller() public {
        DeployRobobetToken script = new DeployRobobetToken();
        RobobetToken token = script.deploy();
        // `new` inside `deploy()` is issued by the script contract, so it is the deployer.
        assertEq(token.balanceOf(address(script)), token.TOTAL_SUPPLY());
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.name(), "robobet");
        assertEq(token.symbol(), "ROBOBET");
    }
}
