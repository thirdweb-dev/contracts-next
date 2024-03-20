// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IHookInfo {
    /*//////////////////////////////////////////////////////////////
                            STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @dev Enum for the type of call to be made in the fallback function.
    enum CallType {
        CALL,
        STATIC_CALL,
        DELEGATE_CALL
    }

    /// @dev Struct for the function in the hook contract to be called in the core contract fallback.
    struct HookFallbackFunction {
        bytes4 functionSelector;
        CallType callType;
    }

    /**
     *  @notice Struct for the hook information.
     *  @param hookFlags The flags for the hook functions implemented by the hook contract.
     *  @param hookFallbackFunctions The functions in the hook contract to be called in the core contract fallback.
     */
    struct HookInfo {
        uint256 hookFlags;
        HookFallbackFunction[] hookFallbackFunctions;
    }
}
