// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// todo: replace delegate call by a parsing like: byte1 : fct + encode packed data

/**
 * @title InternalMulticall
 * @dev Abstract contract that enables batching multiple function calls to itself in a single transaction
 * @notice This contract uses delegatecall to execute multiple functions while preserving msg.sender context
 */
abstract contract InternalMulticall {
    // Events
    event MulticallExecuted(address indexed caller, uint256 callsCount, uint256 gasUsed);
    event MulticallFailed(address indexed caller, uint256 failedIndex, string reason);

    /**
     * @dev Execute multiple function calls in a single transaction
     * @param data Array of encoded function calls
     * @return results Array of return data from each function call
     * @notice If any call fails, the entire transaction reverts
     */
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results) {
        uint256 gasStart = gasleft();
        results = new bytes[](data.length);

        for (uint256 i = 0; i < data.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(data[i]);

            if (!success) {
                _handleFailure(result, i);
            }

            results[i] = result;
        }

        uint256 gasUsed = gasStart - gasleft();
        emit MulticallExecuted(msg.sender, data.length, gasUsed);

        return results;
    }

    /**
     * @dev Internal function to handle call failures
     * @param result The return data from the failed call
     * @param index The index of the failed call
     */
    function _handleFailure(bytes memory result, uint256 index) internal pure {
        string memory reason = _getRevertReason(result);
        revert(string(abi.encodePacked("Multicall failed at index ", _toString(index), ": ", reason)));
    }

    /**
     * @dev Extract revert reason from return data
     * @param result Return data from failed call
     * @return reason The revert reason string
     */
    function _getRevertReason(bytes memory result) internal pure returns (string memory reason) {
        if (result.length < 68) {
            return "Unknown error";
        }

        assembly {
            result := add(result, 0x04)
        }

        return abi.decode(result, (string));
    }

    /**
     * @dev Convert uint256 to string
     * @param value Value to convert
     * @return String representation of the value
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
