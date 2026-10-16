// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title robobet (ROBOBET)
/// @notice Put your fate in the hands of SUPERINTELLIGENCE. X: x.com/robobet_fun
/// @dev A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
/// deployer (`msg.sender`), which on launch is the IMD ProjectFactory. There is no owner, no
/// mint, no burn, no pause, no blocklist and no fee: every transfer moves exactly what it says,
/// so the launch flows (factory -> distributor -> claimants, factory -> pool, pool <-> traders)
/// all arrive whole. The constructor calls no other contract.
///
/// The contract is self-contained: it vendors no library, so there is no linked or delegated
/// code anywhere in its runtime.
contract RobobetToken {
    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    /// @dev `sender` tried to move `needed` but holds only `balance`.
    error ERC20InsufficientBalance(address sender, uint256 balance, uint256 needed);
    /// @dev `spender` tried to spend `needed` on behalf of a holder but was allowed only `allowance`.
    error ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    /// @dev The zero address can neither send, receive, approve nor be approved.
    error ERC20InvalidSender(address sender);
    error ERC20InvalidReceiver(address receiver);
    error ERC20InvalidApprover(address approver);
    error ERC20InvalidSpender(address spender);

    // ------------------------------------------------------------------
    // Events (ERC-20)
    // ------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    string public constant name = "robobet";
    string public constant symbol = "ROBOBET";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 ROBOBET in minor units (18 decimals). This is the total supply
    /// forever: nothing can mint after the constructor.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(address account => uint256) private _balances;
    mapping(address owner => mapping(address spender => uint256)) private _allowances;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    /// @notice Mints the entire fixed supply to the deployer. On launch the deployer is the
    /// factory, which pays the supply out (swarm share, pool seed, remainder) itself.
    constructor() {
        _balances[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ------------------------------------------------------------------
    // ERC-20 views
    // ------------------------------------------------------------------

    /// @notice Always `TOTAL_SUPPLY`: there is no mint and no burn.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ------------------------------------------------------------------
    // ERC-20 actions
    // ------------------------------------------------------------------

    /// @notice Moves `value` from the caller to `to`. Reverts on insufficient balance or a zero receiver.
    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @notice Sets the caller's allowance for `spender` to `value` (no increase/decrease semantics).
    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    /// @notice Moves `value` from `from` to `to` on the strength of the caller's allowance.
    /// An allowance of `type(uint256).max` is treated as infinite and is not decremented.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) private {
        if (from == address(0)) revert ERC20InvalidSender(address(0));
        if (to == address(0)) revert ERC20InvalidReceiver(address(0));
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);
        unchecked {
            // fromBalance >= value, and the sum of all balances is the fixed supply, so no overflow.
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _approve(address owner, address spender, uint256 value) private {
        if (owner == address(0)) revert ERC20InvalidApprover(address(0));
        if (spender == address(0)) revert ERC20InvalidSpender(address(0));
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) private {
        uint256 current = _allowances[owner][spender];
        if (current == type(uint256).max) return;
        if (current < value) revert ERC20InsufficientAllowance(spender, current, value);
        unchecked {
            _allowances[owner][spender] = current - value;
        }
        emit Approval(owner, spender, current - value);
    }
}
