// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {RobobetToken} from "../src/RobobetToken.sol";

/// @notice Reviewable deployment of the robobet token.
/// @dev On the IMD launch the ProjectFactory deploys the token from its bytecode through
/// `launchCustom`, so this script is not what launches it. It exists so the deployment can be
/// read, rehearsed on a local chain and tested: `deploy()` is the whole deployment and takes no
/// configuration, because the token has no constructor arguments. The deployer of the
/// transaction receives the whole supply.
contract DeployRobobetToken is Script {
    /// @notice Deploys the token. The caller of the creation transaction receives the full supply.
    function deploy() public returns (RobobetToken token) {
        token = new RobobetToken();
    }

    /// @notice Broadcast entry point for a manual deployment (e.g. a rehearsal on anvil).
    function run() external returns (RobobetToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
