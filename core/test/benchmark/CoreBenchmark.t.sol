// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {IExtensionContract, IExtensionTypes} from "src/interface/IExtensionContract.sol";
import {CoreContract} from "src/core/CoreContract.sol";
import {ERC20Core} from "src/core/token/ERC20Core.sol";

contract MockBase {
    uint256 internal constant NUMBER_OF_CALLBACK = 10;

    function getFunctionSignature()
        internal
        pure
        virtual
        returns (bytes4[] memory functions)
    {
        functions = new bytes4[](NUMBER_OF_CALLBACK);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i] = bytes4(uint32(i));
        }
    }
}

contract MockCoreMinimal is MockBase, CoreContract {
    function getSupportedCallbackFunctions()
        public
        pure
        override
        returns (SupportedCallbackFunction[] memory supportedCallbackFunctions)
    {
        supportedCallbackFunctions = getCallbackFunctions();
    }

    function getCallbackFunctions()
        internal
        pure
        returns (SupportedCallbackFunction[] memory functions)
    {
        functions = new SupportedCallbackFunction[](NUMBER_OF_CALLBACK);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i] = SupportedCallbackFunction({
                selector: bytes4(uint32(i)),
                order: CallbackOrder.BEFORE,
                mode: CallbackMode.OPTIONAL
            });
        }
    }

    function _isAuthorizedToInstallExtensions(
        address /* _target */
    ) internal pure override returns (bool) {
        return true;
    }

    function _isAuthorizedToCallExtensionFunctions(
        address /*_target*/
    ) internal pure override returns (bool) {
        return true;
    }
}

contract MockCore is MockBase, CoreContract {
    function getSupportedCallbackFunctions()
        public
        pure
        override
        returns (SupportedCallbackFunction[] memory supportedCallbackFunctions)
    {
        supportedCallbackFunctions = getCallbackFunctions();
    }

    function getCallbackFunctions()
        internal
        pure
        returns (SupportedCallbackFunction[] memory functions)
    {
        functions = new SupportedCallbackFunction[](NUMBER_OF_CALLBACK + 1);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i] = SupportedCallbackFunction({
                selector: bytes4(uint32(i)),
                order: CallbackOrder.BEFORE,
                mode: CallbackMode.OPTIONAL
            });
        }

        functions[NUMBER_OF_CALLBACK] = SupportedCallbackFunction({
            selector: this.callbackFunctionOne.selector,
            order: CallbackOrder.BEFORE,
            mode: CallbackMode.REQUIRED
        });
    }

    function callbackFunctionOne() external {
        _callExtensionCallback(
            msg.sig,
            abi.encodeCall(this.callbackFunctionOne, ())
        );
    }

    function _isAuthorizedToInstallExtensions(
        address /* _target */
    ) internal pure override returns (bool) {
        return true;
    }

    function _isAuthorizedToCallExtensionFunctions(
        address /*_target*/
    ) internal pure override returns (bool) {
        return true;
    }
}

contract MockExtension is MockBase, IExtensionContract {
    function onInstall(bytes memory data) external {}

    function onUninstall(bytes memory data) external {}

    function getExtensionConfig()
        external
        pure
        override
        returns (ExtensionConfig memory config)
    {
        config.callbackFunctions = getFunctionSignature();
    }
}

contract MockExtensionWithFunctions is MockBase, IExtensionContract {
    event CallbackFunctionOne();

    function onInstall(bytes memory data) external {}

    function onUninstall(bytes memory data) external {}

    function getFunctionSignature()
        internal
        pure
        override
        returns (bytes4[] memory functions)
    {
        functions = new bytes4[](NUMBER_OF_CALLBACK + 1);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i] = bytes4(uint32(i));
        }
        functions[NUMBER_OF_CALLBACK] = this.callbackFunctionOne.selector;
    }

    function getExtensionConfig()
        external
        pure
        override
        returns (ExtensionConfig memory config)
    {
        config.callbackFunctions = getFunctionSignature();

        ExtensionFunction[] memory functions = new ExtensionFunction[](6);
        functions[0] = ExtensionFunction({
            selector: bytes4(keccak256("notPermissioned_call()")),
            callType: IExtensionTypes.CallType.CALL,
            permissioned: false
        });
        functions[1] = ExtensionFunction({
            selector: bytes4(keccak256("notPermissioned_delegatecall()")),
            callType: IExtensionTypes.CallType.DELEGATECALL,
            permissioned: false
        });
        functions[2] = ExtensionFunction({
            selector: bytes4(keccak256("notPermissioned_staticcall()")),
            callType: IExtensionTypes.CallType.STATICCALL,
            permissioned: false
        });
        functions[3] = ExtensionFunction({
            selector: bytes4(keccak256("permissioned_call()")),
            callType: IExtensionTypes.CallType.CALL,
            permissioned: true
        });
        functions[4] = ExtensionFunction({
            selector: bytes4(keccak256("permissioned_delegatecall()")),
            callType: IExtensionTypes.CallType.DELEGATECALL,
            permissioned: true
        });
        functions[5] = ExtensionFunction({
            selector: bytes4(keccak256("permissioned_staticcall()")),
            callType: IExtensionTypes.CallType.STATICCALL,
            permissioned: true
        });
        config.extensionABI = functions;
    }

    function callbackFunctionOne() external {
        emit CallbackFunctionOne();
    }

    function notPermissioned_call() external {}

    function notPermissioned_delegatecall() external {}

    function notPermissioned_staticcall() external view {}

    function permissioned_call() external {}

    function permissioned_delegatecall() external {}

    function permissioned_staticcall() external view {}
}

contract CoreBenchmark is Test {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Target test contracts
    MockCore public core;
    MockExtension public extension;
    MockCore public coreWithExtensions;
    MockCore public coreWithExtensionsNoCallback;
    MockExtensionWithFunctions public extensionWithFunctions;

    function setUp() public {
        core = new MockCore();
        coreWithExtensions = new MockCore();
        coreWithExtensionsNoCallback = new MockCore();
        extension = new MockExtension();
        extensionWithFunctions = new MockExtensionWithFunctions();

        coreWithExtensionsNoCallback.installExtension(address(extension), "");
        coreWithExtensions.installExtension(
            address(extensionWithFunctions),
            ""
        );
    }

    function test_deployCore() public {
        new MockCoreMinimal();
    }

    function test_deployExtension() public {
        new MockExtension();
    }

    function test_installExtension() public {
        core.installExtension(address(extension), "");
    }

    function test_uninstallExtension() public {
        vm.pauseGasMetering();
        core.installExtension(address(extension), "");
        vm.resumeGasMetering();

        core.uninstallExtension(address(extension), "");
    }

    function test_extension_callFunction_notPermissionedExternal() public {
        (bool success, ) = address(extensionWithFunctions).call(
            abi.encodeCall(MockExtensionWithFunctions.notPermissioned_call, ())
        );
        vm.assertTrue(success);
    }

    function test_extension_callFunction_notPermissionedDelegate() public {
        (bool success, ) = address(extensionWithFunctions).call(
            abi.encodeCall(
                MockExtensionWithFunctions.notPermissioned_delegatecall,
                ()
            )
        );
        vm.assertTrue(success);
    }

    function test_core_callFunction_notPermissionedExternal() public {
        (bool success, ) = address(coreWithExtensions).call(
            abi.encodeCall(MockExtensionWithFunctions.notPermissioned_call, ())
        );
        vm.assertTrue(success);
    }

    function test_core_callFunction_notPermissionedDelegate() public {
        (bool success, ) = address(coreWithExtensions).call(
            abi.encodeCall(
                MockExtensionWithFunctions.notPermissioned_delegatecall,
                ()
            )
        );
        vm.assertTrue(success);
    }

    function test_core_callCallbackFunction_required() public {
        (bool success, ) = address(coreWithExtensions).call(
            abi.encodeCall(coreWithExtensions.callbackFunctionOne, ())
        );
        vm.assertTrue(success);
    }

    function test_core_callFunction_callback_callbackFunctionRequired() public {
        vm.expectRevert(CoreContract.CallbackFunctionRequired.selector);
        address(coreWithExtensionsNoCallback).call(
            abi.encodeCall(coreWithExtensionsNoCallback.callbackFunctionOne, ())
        );
    }
}
