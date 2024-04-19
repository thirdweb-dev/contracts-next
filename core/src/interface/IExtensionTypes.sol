// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IExtensionTypes {
    /*//////////////////////////////////////////////////////////////
                            STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @dev Enum for the type of call to be made to an extension function.
    enum CallType {
        STATICCALL,
        CALL,
        DELEGATECALL
    }

    /// @dev Struct for an extension function. Installing an extension in a core adds its extension functions to the core's ABI.
    struct ExtensionFunction {
        bytes4 selector;
        CallType callType;
        bool permissioned;
    }

    /// @notice All extension functions and supported callback functions of an extension contract.
    struct ExtensionConfig {
        bytes4[] callbackFunctions;
        ExtensionFunction[] extensionABI;
    }
}