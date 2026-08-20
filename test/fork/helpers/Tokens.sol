// SPDX-License-Identifier: GPL-3.0
pragma solidity =0.8.26;

/// @notice A minimal, well-behaved ERC20 for spinning up throwaway V3 pools on the fork.
/// @dev Hand-rolled rather than reused from test/Mocks because those are pinned `^0.8.28` and this
/// tree compiles the proxy at exactly 0.8.26.
contract PlainToken {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @notice Burns a percentage of every transfer.
/// @dev The proxy pays pools with `safeTransferFrom(payer, pool, amountOwed)` and never re-checks
/// what landed. A V3 pool measures its own balance before and after, so a token that delivers less
/// than was sent makes the pool's own accounting reject the payment.
contract FeeOnTransferToken is PlainToken {
    uint256 public immutable FEE_BPS;

    constructor(uint256 feeBps) PlainToken("Fee On Transfer", "FOT", 18) {
        FEE_BPS = feeBps;
    }

    function _move(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}
