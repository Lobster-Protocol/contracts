// SPDX-License-Identifier: MIT
pragma solidity >=0.8.20;

/// @dev Zodiac's `Enum.Operation`
enum Operation {
    Call,
    DelegateCall
}

/// @title Minimal interface of a Zodiac Roles v2 modifier
/// @dev Only the subset {V4LiquidityTrampoline} uses. Mirrors gnosisguild/zodiac-modifier-roles
/// `Roles.sol` and zodiac `Modifier.sol`.
interface IRoles {
    /// @notice The Safe the modifier acts for
    function avatar() external view returns (address);

    /// @notice The contract the modifier calls through (normally the avatar itself)
    function target() external view returns (address);

    /// @notice Executes a call from the avatar, if `roleKey` allows it and msg.sender holds that role
    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    )
        external
        returns (bool success);

    /// @notice Same as {execTransactionWithRole}, also returning the call's return data
    function execTransactionWithRoleReturnData(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    )
        external
        returns (bool success, bytes memory returnData);
}

/// @title Zodiac Roles v2 custom condition (`ICustomCondition`)
/// @dev `operation` is declared `uint8`, the ABI type of `Enum.Operation`, so the selector is the
/// same, and an out-of-range value cannot make the call revert while its arguments are decoded.
interface ICustomCondition {
    /// @param to The target of the call being authorized
    /// @param value Its value
    /// @param data Its full calldata
    /// @param operation 0 = Call, 1 = DelegateCall
    /// @param location Offset of the parameter the condition is attached to (unused here)
    /// @param size Size of that parameter (unused here)
    /// @param extra The condition's 12 extra bytes from the Roles config (unused here)
    /// @return success Whether the call is allowed
    /// @return reason Why not, when it is not
    function check(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 location,
        uint256 size,
        bytes12 extra
    )
        external
        view
        returns (bool success, bytes32 reason);
}
