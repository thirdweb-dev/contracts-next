// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

// Target contract
import {IExtensionConfig} from "./interface/IExtensionConfig.sol";
import {ModularExtension} from "./ModularExtension.sol";
import {ModularCoreUpgradeable} from "./ModularCoreUpgradeable.sol";

contract DemoBase {
    uint256 internal constant NUMBER_OF_CALLBACK = 10;

    function getCallbacks() internal pure virtual returns (IExtensionConfig.CallbackFunction[] memory functions) {
        functions = new IExtensionConfig.CallbackFunction[](NUMBER_OF_CALLBACK);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i].selector = bytes4(uint32(i));
            functions[i].callType = IExtensionConfig.CallType.CALL;
        }
    }
}

contract DemoCore is DemoBase, ModularCoreUpgradeable {
    constructor(address _erc1967FactoryAddress, address _owner) ModularCoreUpgradeable(_erc1967FactoryAddress) {
        _initializeOwner(_owner);
    }

    function getSupportedCallbackFunctions()
        public
        pure
        override
        returns (SupportedCallbackFunction[] memory supportedCallbackFunctions)
    {
        supportedCallbackFunctions = getCallbackFunctions();
    }

    function getCallbackFunctions() internal pure returns (SupportedCallbackFunction[] memory functions) {
        functions = new SupportedCallbackFunction[](NUMBER_OF_CALLBACK + 1);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i] = SupportedCallbackFunction({selector: bytes4(uint32(i)), mode: CallbackMode.OPTIONAL});
        }

        functions[NUMBER_OF_CALLBACK] =
            SupportedCallbackFunction({selector: this.callbackFunctionOne.selector, mode: CallbackMode.REQUIRED});
    }

    function callbackFunctionOne() external {
        _executeCallbackFunction(msg.sig, abi.encodeCall(this.callbackFunctionOne, ()));
    }
}

contract DemoExtensionWithFunctions is DemoBase, ModularExtension {
    event CallbackFunctionOne();
    event FallbackFunctionCalled();

    uint256 public constant CALLER_ROLE = 1 << 5;

    uint256 private number;

    function onInstall(address sender, bytes memory data) external {}

    function onUninstall(address sender, bytes memory data) external {}

    function getCallbacks() internal pure override returns (IExtensionConfig.CallbackFunction[] memory functions) {
        functions = new IExtensionConfig.CallbackFunction[](NUMBER_OF_CALLBACK + 1);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i].selector = bytes4(uint32(i));
            functions[i].callType = IExtensionConfig.CallType.CALL;
        }
        functions[NUMBER_OF_CALLBACK].selector = this.callbackFunctionOne.selector;
        functions[NUMBER_OF_CALLBACK].callType = IExtensionConfig.CallType.CALL;
    }

    function getExtensionConfig() external pure virtual override returns (ExtensionConfig memory config) {
        config.callbackFunctions = getCallbacks();

        FallbackFunction[] memory functions = new FallbackFunction[](8);
        functions[0] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: 0
        });
        functions[1] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: 0
        });
        functions[2] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        functions[3] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[4] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: CALLER_ROLE
        });
        functions[5] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: CALLER_ROLE
        });
        functions[6] = FallbackFunction({
            selector: bytes4(keccak256("setNumber(uint256)")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[7] = FallbackFunction({
            selector: bytes4(keccak256("getNumber()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        config.fallbackFunctions = functions;
    }

    function setNumber(uint256 _number) external {
        number = _number;
    }

    function getNumber() external view returns (uint256) {
        return number;
    }

    function callbackFunctionOne() external {
        emit CallbackFunctionOne();
    }

    function notPermissioned_call() external {
        emit FallbackFunctionCalled();
    }

    function notPermissioned_delegatecall() external {}

    function notPermissioned_staticcall() external view {}

    function permissioned_call() external {}

    function permissioned_delegatecall() external {}

    function permissioned_staticcall() external view {}
}

contract DemoExtensionAlternate is DemoExtensionWithFunctions {
    function getExtensionConfig() external pure virtual override returns (ExtensionConfig memory config) {
        config.callbackFunctions = getCallbacks();

        FallbackFunction[] memory functions = new FallbackFunction[](9);
        functions[0] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: 0
        });
        functions[1] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: 0
        });
        functions[2] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        functions[3] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[4] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: CALLER_ROLE
        });
        functions[5] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: CALLER_ROLE
        });
        functions[6] = FallbackFunction({
            selector: bytes4(keccak256("setNumber()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[7] = FallbackFunction({
            selector: bytes4(keccak256("getNumber()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        functions[8] = FallbackFunction({
            selector: bytes4(keccak256("someNewFunction()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: 0
        });
        config.fallbackFunctions = functions;
    }

    event SomeNewEvent();

    function someNewFunction() external {
        emit SomeNewEvent();
    }
}

contract DemoExtensionWithInterfaceId is DemoBase, ModularExtension {
    event CallbackFunctionOne();
    event FallbackFunctionCalled();

    uint256 public constant CALLER_ROLE = 1 << 5;

    uint256 private number;

    function onInstall(address sender, bytes memory data) external {}

    function onUninstall(address sender, bytes memory data) external {}

    function getCallbacks() internal pure override returns (IExtensionConfig.CallbackFunction[] memory functions) {
        functions = new IExtensionConfig.CallbackFunction[](NUMBER_OF_CALLBACK + 1);
        for (uint256 i = 0; i < NUMBER_OF_CALLBACK; i++) {
            functions[i].selector = bytes4(uint32(i));
            functions[i].callType = IExtensionConfig.CallType.CALL;
        }
        functions[NUMBER_OF_CALLBACK].selector = this.callbackFunctionOne.selector;
        functions[NUMBER_OF_CALLBACK].callType = IExtensionConfig.CallType.CALL;
    }

    function getExtensionConfig() external pure virtual override returns (ExtensionConfig memory config) {
        config.callbackFunctions = getCallbacks();

        FallbackFunction[] memory functions = new FallbackFunction[](8);
        functions[0] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: 0
        });
        functions[1] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: 0
        });
        functions[2] = FallbackFunction({
            selector: bytes4(keccak256("notPermissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        functions[3] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_call()")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[4] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_delegatecall()")),
            callType: IExtensionConfig.CallType.DELEGATECALL,
            permissionBits: CALLER_ROLE
        });
        functions[5] = FallbackFunction({
            selector: bytes4(keccak256("permissioned_staticcall()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: CALLER_ROLE
        });
        functions[6] = FallbackFunction({
            selector: bytes4(keccak256("setNumber(uint256)")),
            callType: IExtensionConfig.CallType.CALL,
            permissionBits: CALLER_ROLE
        });
        functions[7] = FallbackFunction({
            selector: bytes4(keccak256("getNumber()")),
            callType: IExtensionConfig.CallType.STATICCALL,
            permissionBits: 0
        });
        config.fallbackFunctions = functions;
        config.requiredInterfaceId = 0x12121212; // arbitrary interface id
    }

    function setNumber(uint256 _number) external {
        number = _number;
    }

    function getNumber() external view returns (uint256) {
        return number;
    }

    function callbackFunctionOne() external {
        emit CallbackFunctionOne();
    }

    function notPermissioned_call() external {
        emit FallbackFunctionCalled();
    }

    function notPermissioned_delegatecall() external {}

    function notPermissioned_staticcall() external view {}

    function permissioned_call() external {}

    function permissioned_delegatecall() external {}

    function permissioned_staticcall() external view {}
}