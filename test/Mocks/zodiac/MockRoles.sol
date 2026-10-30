// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.20;

import {Operation, ICustomCondition} from "../../../src/interfaces/zodiac/IRoles.sol";
import {MockSafe} from "./MockSafe.sol";

/// @notice A minimal Zodiac Roles v2 modifier: the checks LobsterProxy's V4 liquidity relies on, nothing more.
/// @dev Mirrors Roles v2 where it matters here:
/// - `execTransactionWithRole*` require msg.sender to be an enabled module (`NotAuthorized`) and a
///   member of the role (`NoMembership`);
/// - per (role, target, selector) rules: not allowed (`FunctionNotAllowed`), value without Send
///   (`SendNotAllowed`), a Custom condition (`ConditionViolation(reason)`, called with the full
///   calldata exactly like Roles' `_custom`), or a parameter that must equal the avatar;
/// - the call is executed through `target.execTransactionFromModuleReturnData`, and a failed call
///   reverts with `ModuleTransactionFailed()` when `shouldRevert`, hiding the inner reason.
/// No reentrancy guard, as in Roles v2: the trampoline re-enters it from inside a call it is making.
/// Not modelled: allowances, multi-entrypoint, delegatecalls, the rest of the condition language.
contract MockRoles {
    error NotAuthorized(address module);
    error NoMembership();
    error FunctionNotAllowed();
    error SendNotAllowed();
    error ConditionViolation(bytes32 reason);
    error ModuleTransactionFailed();

    struct Rule {
        bool allowed;
        bool send;
        address customCondition;
        /// @dev 1 + index of a parameter that must equal the avatar; 0 for none
        uint256 avatarParam;
    }

    address private immutable _owner;
    address public avatar;
    address public target;
    mapping(address module => bool) public isModuleEnabled;
    mapping(bytes32 roleKey => mapping(address member => bool)) public isMember;
    mapping(bytes32 roleKey => mapping(address to => mapping(bytes4 selector => Rule))) public rules;

    constructor(address _avatar, address _target) {
        _owner = msg.sender;
        avatar = _avatar;
        target = _target;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "MockRoles: not owner");
        _;
    }

    // --- configuration (the Safe's owners on a real deployment)

    function setAvatar(address a) external onlyOwner {
        avatar = a;
    }

    function setTarget(address t) external onlyOwner {
        target = t;
    }

    function enableModule(address module) external onlyOwner {
        isModuleEnabled[module] = true;
    }

    function assignRole(address module, bytes32 roleKey, bool member) external onlyOwner {
        isMember[roleKey][module] = member;
    }

    function allowFunction(bytes32 roleKey, address to, bytes4 selector, bool send) external onlyOwner {
        rules[roleKey][to][selector] = Rule({allowed: true, send: send, customCondition: address(0), avatarParam: 0});
    }

    function scopeCustomCondition(bytes32 roleKey, address to, bytes4 selector, address condition) external onlyOwner {
        rules[roleKey][to][selector] = Rule({allowed: true, send: false, customCondition: condition, avatarParam: 0});
    }

    function scopeParamEqualToAvatar(bytes32 roleKey, address to, bytes4 selector, uint256 index) external onlyOwner {
        rules[roleKey][to][selector] =
            Rule({allowed: true, send: false, customCondition: address(0), avatarParam: index + 1});
    }

    // --- execution

    function execTransactionWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    )
        external
        returns (bool success)
    {
        (success,) = _execWithRole(to, value, data, operation, roleKey, shouldRevert);
    }

    function execTransactionWithRoleReturnData(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    )
        external
        returns (bool success, bytes memory returnData)
    {
        return _execWithRole(to, value, data, operation, roleKey, shouldRevert);
    }

    function _execWithRole(
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation,
        bytes32 roleKey,
        bool shouldRevert
    )
        private
        returns (bool success, bytes memory returnData)
    {
        if (!isModuleEnabled[msg.sender]) revert NotAuthorized(msg.sender);
        if (!isMember[roleKey][msg.sender]) revert NoMembership();
        _authorize(roleKey, to, value, data, operation);
        (success, returnData) =
            MockSafe(payable(target)).execTransactionFromModuleReturnData(to, value, data, operation);
        if (shouldRevert && !success) revert ModuleTransactionFailed();
    }

    function _authorize(
        bytes32 roleKey,
        address to,
        uint256 value,
        bytes calldata data,
        Operation operation
    )
        private
        view
    {
        if (operation != Operation.Call || data.length < 4) revert FunctionNotAllowed();
        Rule memory rule = rules[roleKey][to][bytes4(data[:4])];
        if (!rule.allowed) revert FunctionNotAllowed();
        if (value > 0 && !rule.send) revert SendNotAllowed();
        if (rule.customCondition != address(0)) {
            (bool ok, bytes32 reason) = ICustomCondition(rule.customCondition)
                .check(to, value, data, uint8(operation), 4, data.length - 4, bytes12(0));
            if (!ok) revert ConditionViolation(reason);
        }
        if (rule.avatarParam != 0) {
            uint256 offset = 4 + 32 * (rule.avatarParam - 1);
            if (data.length < offset + 32 || address(uint160(uint256(bytes32(data[offset:offset + 32])))) != avatar) {
                revert ConditionViolation("ParameterNotAllowed");
            }
        }
    }
}
