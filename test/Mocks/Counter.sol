// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// Used to allow or deny ops in opValidators
bytes4 constant UNAUTHORIZED = bytes4(0x00000001);
bytes4 constant AUTHORIZED = bytes4(0x00000002);
// used to test pre and post hooks
bytes4 constant UNAUTHORIZED_PREHOOK = bytes4(0x00000003);
bytes4 constant UNAUTHORIZED_POSTHOOK = bytes4(0x00000004);
//

contract Counter {
    uint256 public value = 0;

    function ping() external pure returns (string memory) {
        return "pong";
    }

    function increment() public {
        value++;
    }

    function incrementWithAmount(uint256 amount) external {
        value += amount;
    }

    fallback() external {
        // use to test allowed / unauthorized selectors
        // always return true if the selector is known
        if (
            msg.sig == UNAUTHORIZED || msg.sig == AUTHORIZED || msg.sig == UNAUTHORIZED_PREHOOK
                || msg.sig == UNAUTHORIZED_POSTHOOK
        ) {
            increment();
            return;
        }

        revert("Unknown selector");
    }
}
