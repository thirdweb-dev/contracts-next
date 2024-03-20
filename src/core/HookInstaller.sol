// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {LibBit} from "@solady/utils/LibBit.sol";

import {IHook} from "../interface/hook/IHook.sol";
import {IHookInstaller} from "../interface/hook/IHookInstaller.sol";

abstract contract HookInstaller is IHookInstaller {
    using LibBit for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Bits representing all hooks installed.
    uint256 private installedHooks_;

    /// @notice Mapping from hook bits representation => implementation of the hook.
    mapping(uint256 => address) private hookImplementationMap_;

    mapping(bytes4 => HookFallbackFunctionCall) private hookFallbackFunctionCallMap_;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the caller is not authorized to install/uninstall hooks.
    error HookInstallerNotAuthorized();

    /// @notice Emitted on failure to perform a call to a hook contract.
    error HookInstallerHookCallFailed();

    /// @notice Emitted when the caller attempts to write to a hook contract without permission.
    error HookInstallerUnauthorizedWrite();

    /// @notice Emitted when the caller attempts to install a hook that is already installed.
    error HookInstallerHookAlreadyInstalled();

    /// @notice Emitted on attempt to call an uninstalled hook.
    error HookInstallerHookNotInstalled();

    /// @notice Emitted on installing a hook that is incompatible with the hook installer.
    error HookInstallerIncompatibleHook();

    /// @notice Emitted when installing or uninstalling the zero address as a hook.
    error HookInstallerZeroAddress();

    /// @notice Emitted on attempt to initialize a hook with invalid msg.value.
    error HookInstallerInvalidMsgValue();

    /// @notice Emitted when the caller attempts to call a non-existent hook fallback function.
    error HookInstallerFallbackFunctionDoesNotExist();

    /// @notice Emitted on attempt to overwrite an in-use hook fallback function.
    error HookInstallerHookFallbackFunctionUsed(bytes4 functionSelector);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Retusn the implementation of a given hook, if any.
     *  @param _flag The bits representing the hook.
     *  @return impl The implementation of the hook.
     */
    function getHookImplementation(uint256 _flag) public view returns (address) {
        return hookImplementationMap_[_flag];
    }

    /**
     *  @notice Returns the call destination of a hook fallback function.
     *  @param _selector The selector of the function.
     *  @return target The fallback function call info including the target address, function selector, and call type.
     */
    function getHookFallbackFunctionCall(bytes4 _selector) external view returns (HookFallbackFunctionCall memory) {
        return hookFallbackFunctionCallMap_[_selector];
    }

    /*//////////////////////////////////////////////////////////////
                        FALLBACK FUNCTION
    //////////////////////////////////////////////////////////////*/

    fallback() external payable {
        HookFallbackFunctionCall memory callInfo = hookFallbackFunctionCallMap_[msg.sig];

        if (callInfo.target == address(0)) {
            revert HookInstallerFallbackFunctionDoesNotExist();
        }

        if (callInfo.callType != CallType.STATIC_CALL && !_canWriteToHooks(msg.sender)) {
            revert HookInstallerUnauthorizedWrite();
        }

        if (callInfo.callType == CallType.CALL) {
            _callAndReturn(callInfo.target, msg.value);
        } else if (callInfo.callType == CallType.DELEGATE_CALL) {
            _delegatecallAndReturn(callInfo.target);
        } else if (callInfo.callType == CallType.STATIC_CALL) {
            _staticcallAndReturn(callInfo.target);
        }
    }

    receive() external payable virtual {}

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Installs a hook in the contract.
     *  @dev Maps all hook functions implemented by the hook to the hook's address.
     *  @param _params The parameters for installing a hook and initializing it with some data.
     */
    function installHook(InstallHookParams memory _params) external payable {
        // Validate the caller's permissions.
        if (!_canUpdateHooks(msg.sender)) {
            revert HookInstallerNotAuthorized();
        }
        // Validate init calldata and value
        if (_params.initCallValue != msg.value) {
            revert HookInstallerInvalidMsgValue();
        }
        _installHook(_params);
    }

    /**
     *  @notice Uninstalls a hook in the contract.
     *  @dev Unlike `installHook`, we do not accept a hook contract address as a parameter since it is possible
     *       that the hook contract returns different hook functions compared to when it was installed. This could
     *       lead to a mismatch. Instead, we use the bit representation of the hooks to uninstall.
     *  @param _hooksToUninstall The bit representation of the hooks to uninstall.
     */
    function uninstallHook(uint256 _hooksToUninstall) external {
        // Validate the caller's permissions.
        if (!_canUpdateHooks(msg.sender)) {
            revert HookInstallerNotAuthorized();
        }

        // Validate the hook is compatible with the hook installer.
        uint256 flag = 2 ** _maxHookFlag();
        if (flag < _highestBitToZero(_hooksToUninstall)) {
            revert HookInstallerIncompatibleHook();
        }

        // 1. For each hook function i.e. flag <= 2 ** _maxHookFlag(): If the installed hook contract
        //    implements the hook function, delete it as the implementation of the hook function.
        //
        // 2. Update the tracked installed hooks of the contract.
        uint256 currentActivehooks = installedHooks_;
        while (flag > 1) {
            if (_hooksToUninstall & flag > 0) {
                currentActivehooks &= ~flag;
                delete hookImplementationMap_[flag];
            }
            flag >>= 1;
        }
        installedHooks_ = currentActivehooks;

        emit HooksUninstalled(_hooksToUninstall);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @dev Installs a hook in the contract. We extract this logic in an internal function to allow
     *       re-use inside a contract constructor / initializer to isntall hooks during contract creation.
     */
    function _installHook(InstallHookParams memory _params) internal {
        // Validate hook address.
        if (address(_params.hook) == address(0)) {
            revert HookInstallerZeroAddress();
        }

        // Get flags of all the hook functions for which to set the hook contract
        // as their implementation.
        HookInfo memory hookInfo = _params.hook.getHookInfo();

        uint256 hooksToInstall = hookInfo.hookFlags;

        // Validate the hook is compatible with the hook installer.
        uint256 flag = 2 ** _maxHookFlag();
        if (flag < _highestBitToZero(hooksToInstall)) {
            revert HookInstallerIncompatibleHook();
        }

        // 1. For each hook function i.e. flag <= 2 ** _maxHookFlag(): If the installed hook contract
        //    implements the hook function, set it as the implementation of the hook function.
        //
        // 2. Update the tracked installed hooks of the contract.
        uint256 currentActivehooks = installedHooks_;
        while (flag > 1) {
            if (hooksToInstall & flag > 0) {
                if (currentActivehooks & flag > 0) {
                    revert HookInstallerHookAlreadyInstalled();
                }
                currentActivehooks |= flag;
                hookImplementationMap_[flag] = address(_params.hook);
            }
            flag >>= 1;
        }
        installedHooks_ = currentActivehooks;

        // Get all the hook fallback functions and map them to the hook contract
        // as their call destination.
        HookFallbackFunction[] memory fallbackFunctions = hookInfo.hookFallbackFunctions;
        for (uint256 i = 0; i < fallbackFunctions.length; i++) {
            bytes4 selector = fallbackFunctions[i].functionSelector;
            if (hookFallbackFunctionCallMap_[selector].target != address(0)) {
                revert HookInstallerHookFallbackFunctionUsed(selector);
            }

            hookFallbackFunctionCallMap_[selector] =
                HookFallbackFunctionCall({target: address(_params.hook), callType: fallbackFunctions[i].callType});
        }

        // Finally, initialize the hook with the given calldata and value.
        if (_params.initCalldata.length > 0) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool success, bytes memory returndata) =
                address(_params.hook).call{value: _params.initCallValue}(_params.initCalldata);
            if (!success) {
                _revert(returndata, HookInstallerHookCallFailed.selector);
            }
        }

        emit HooksInstalled(address(_params.hook), hooksToInstall);
    }

    /// @dev Returns whether the caller can update hooks.
    function _canUpdateHooks(address _caller) internal view virtual returns (bool);

    /// @dev Returns whether the caller can write to hook contracts via the fallback function.
    function _canWriteToHooks(address _caller) internal view virtual returns (bool);

    /// @dev Should return the max flag that represents a hook.
    function _maxHookFlag() internal pure virtual returns (uint8) {
        return 0;
    }

    /// @dev Reverts with the given return data / error message.
    function _revert(bytes memory _returndata, bytes4 _errorSignature) internal pure {
        // Look for revert reason and bubble it up if present
        if (_returndata.length > 0) {
            // The easiest way to bubble the revert reason is using memory via assembly
            /// @solidity memory-safe-assembly
            assembly {
                let returndata_size := mload(_returndata)
                revert(add(32, _returndata), returndata_size)
            }
        } else {
            assembly {
                mstore(0x00, _errorSignature)
                revert(0x1c, 0x04)
            }
        }
    }

    /// @dev delegateCalls an `implementation` smart contract.
    function _delegatecallAndReturn(address implementation) internal virtual {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Call the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // delegatecall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev calls an `implementation` smart contract and returns data.
    function _staticcallAndReturn(address implementation) internal virtual {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Staticcall the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := staticcall(gas(), implementation, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // staticcall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev calls an `implementation` smart contract and returns data.
    function _callAndReturn(address implementation, uint256 _value) internal virtual {
        assembly {
            // Copy msg.data. We take full control of memory in this inline assembly
            // block because it will not return to Solidity code. We overwrite the
            // Solidity scratch pad at memory position 0.
            calldatacopy(0, 0, calldatasize())

            // Staticcall the implementation.
            // out and outsize are 0 because we don't know the size yet.
            let result := call(gas(), implementation, _value, 0, calldatasize(), 0, 0)

            // Copy the returned data.
            returndatacopy(0, 0, returndatasize())

            switch result
            // staticcall returns 0 on error.
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _highestBitToZero(uint256 _value) public pure returns (uint256) {
        if (_value == 0) return 0; // Handle edge case where value is 0
        uint256 index = _value.fls(); // Find the index of the MSB
        return (1 << index); // Shift 1 left by the index of the MSB
    }
}
