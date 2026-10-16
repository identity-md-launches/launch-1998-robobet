# robobet (ROBOBET)

> Put your fate in the hands of SUPERINTELLIGENCE. X: [x.com/robobet_fun](https://x.com/robobet_fun)

A fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Item | Value |
| --- | --- |
| Solidity contract (manifest `token.contract`) | `RobobetToken` (`src/RobobetToken.sol`) |
| `name()` | `robobet` |
| `symbol()` | `ROBOBET` |
| `decimals()` | `18` |
| Total supply | 1,000,000,000 ROBOBET = `1000000000000000000000000000` minor units |
| Constructor arguments | none (`constructorArgs: []`) |
| Minted to | `msg.sender` of the creation transaction, once, in the constructor |
| Owner / admin | none |
| Compiler | solc `0.8.26`, optimizer on (200 runs), `evm_version = "cancun"`, `bytecode_hash = "none"` |

## What the token does

It is a plain ERC-20 and nothing more:

- `transfer`, `approve`, `transferFrom`, `balanceOf`, `allowance`, `totalSupply`, `name`,
  `symbol`, `decimals`, plus the public constant `TOTAL_SUPPLY`.
- An allowance of `type(uint256).max` is treated as infinite and never decremented.
- Transfers to or from the zero address revert; approvals to the zero spender revert; the
  contract does not accept ether and has no fallback.
- Reverts use custom errors (`ERC20InsufficientBalance`, `ERC20InsufficientAllowance`,
  `ERC20InvalidReceiver`, `ERC20InvalidSender`, `ERC20InvalidApprover`, `ERC20InvalidSpender`).

What it deliberately does **not** have, so the launch floor and ordinary holders can rely on it:

- no `mint`, `burn`, `burnFrom`: the supply is `TOTAL_SUPPLY` forever, in both directions;
- no owner, `Ownable`, roles, pause, blocklist, freeze, lock, seize or transfer toggle;
- no fee, tax, reflection or burn on transfer: every flow moves exactly the stated amount;
- no proxy, `DELEGATECALL`, `CALLCODE`, `SELFDESTRUCT`, external library or external call of any
  kind (a test scans the runtime bytecode for the forbidden opcodes);
- no exemptions list: since nothing is taxed, the factory, PoolManager and distributor need no
  special treatment and the constructor takes no launch addresses.

## Assumptions

- The requester asked for a plain token (name, symbol, supply, all minted once to the deployer)
  and described no transfer rules, taxes, vesting or governance, so none were added. Adding any
  later would be a new contract and a new launch.
- "Deployer" is the `msg.sender` of the creation transaction. On the IMD launch that is the
  ProjectFactory, which immediately pays the supply out (see "Launch economics"). Nobody else
  ever holds a privileged position.
- The token's Solidity name is `RobobetToken` (12 characters, within the 32-character manifest
  limit); the long-form name and symbol live in `name()` and `symbol()`.
- The pool pairs the token with IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, 18 decimals)
  at the launch policy's fee (1.25%, `12500`) and tick spacing 60. The deployer derives the
  opening price from the launch's market cap; nothing in this repository fixes it.

## Launch economics (from the job, for the manifest step)

These values are the launch's and are copied into `launch.json` by the manifest step, not by this
repository. They are listed here only so the deployment is reviewable.

| Flow | Share | Destination |
| --- | --- | --- |
| Swarm (contributors + paired seats) | 10% of supply, fixed by the factory | the launch's MerkleDistributor |
| Pool seed (`economics.poolBps = 5000`) | 50% of supply, single-sided | Uniswap v4 pool, ROBOBET/IMD, opened at a 3,000 IMD market cap (`initialMarketCapWei = 3000000000000000000000`) |
| Remainder (`economics.remainderTo`) | 40% of supply | `0xEE2aaA315cf7eD169f93148D30D24Af9318dBb66` |

`test/LaunchFlows.t.sol` rehearses exactly this split with plain transfers and checks that each
leg arrives whole, that the distributor can pay claims out whole, that a pool can pull the seed
through an allowance, that a trader can buy and sell back the exact amount, and that the supply
never changes.

## Deployment parameters

- Chain: Ethereum mainnet (chain id 1).
- Contract: `RobobetToken`, no constructor arguments, no linked libraries, no initializer.
- The creation code is the compiled bytecode as built with the pinned `foundry.toml`
  (`bytecode_hash = "none"` so the deployed bytes are reproducible without a metadata hash).
- IMD's deployer launches the token through `ProjectFactory.launchCustom`; this repository does
  not deploy, broadcast, verify or sign anything, and contains no `launch.json`.
- `script/Deploy.s.sol` is a reviewable rehearsal only: `deploy()` creates the token and is
  called directly by `test/Deploy.t.sol`; `run()` wraps it in a broadcast for a local anvil run.
  It reads no environment variables.

Rehearsal on a local chain, if wanted (not part of the launch):

```sh
anvil &
forge script script/Deploy.s.sol:DeployRobobetToken --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender <any funded anvil account>
```

## After launch

There is nothing to configure: the token has no owner and no settable value. The operational
responsibilities that remain are off-chain:

- **Explorer verification**: the source, compiler (`0.8.26`), optimizer settings (on, 200 runs),
  EVM version (`cancun`) and `bytecode_hash = "none"` are what the verifier needs. This is the
  network's deployer's step after the launch.
- **Key custody**: the remainder (40%) lands on `economics.remainderTo`. Whoever controls that
  wallet controls that allocation; the token itself gives them no power over anyone else's
  balance.
- **Liquidity**: the pool is seeded by the factory at launch. Nothing in the token can add, remove
  or lock liquidity afterwards; that is a matter for the pool position's holder.
- **No upgrade path**: the contract is immutable. A change of behaviour means a new token.

## Repository layout

```
foundry.toml          compiler pins and profile (solc 0.8.26, bytecode_hash = "none")
remappings.txt        forge-std/ -> lib/forge-std/src/
src/RobobetToken.sol  the token
script/Deploy.s.sol   reviewable deployment rehearsal (deploy() is testable, run() broadcasts)
test/RobobetToken.t.sol  ERC-20 success/failure tests, fuzz, admin-surface and bytecode checks
test/LaunchFlows.t.sol   the launch economics rehearsed with plain transfers
test/Deploy.t.sol        the deploy function called directly
lib/forge-std/        forge-std v1.10.0, vendored as plain files (MIT / Apache-2.0)
```

## Building and testing

```sh
forge build
forge test
forge fmt --check
```

The suite has no dependence on the environment, on test order or on the calling address, so it
runs in parallel and with an empty environment. Fuzz tests pass with the verifier's seed
(`FOUNDRY_FUZZ_SEED=0xa1b812d19599fff109032da99a39cc9f8e7d875e0cf479df8cfbb3cd59df9662`) as well
as with random seeds.

## Security notes

Passing tests are not an audit. The checklist in the eth-security reference was applied as
follows: no reentrancy surface (no external calls), no arithmetic beyond checked subtraction with
explicit bounds (the two `unchecked` blocks are guarded by the preceding comparisons and by the
fixed supply), no privileged functions to misuse, no delegatecall or self-destruct, no reliance on
`tx.origin`, timestamps or randomness, and `approve` has the standard ERC-20 overwrite semantics
(the well-known front-running caveat applies to every ERC-20; callers who need it should set the
allowance to zero first). Tools run: `forge build`, `forge test` (fuzz, 256 runs), `forge fmt --check`.
Slither and Mythril were not run in this assignment.
