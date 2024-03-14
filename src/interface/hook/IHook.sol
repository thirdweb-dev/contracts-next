// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IHook {
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all hooks implemented by the contract -- represented in the bits of the returned integer.
    function getHooks() external view returns (uint256 hooksImplemented);

    /// @notice Returns all hook contract functions to register as callable via core contract fallback function.
    function getHookFallbackFunctions() external view returns (bytes4[] memory);
}
