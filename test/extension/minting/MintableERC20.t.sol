// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/forge-std/src/console.sol";

import {Test} from "forge-std/Test.sol";

import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

// Target contract
import {IExtensionConfig} from "src/interface/IExtensionConfig.sol";
import {IModularCore} from "src/interface/IModularCore.sol";
import {ModularExtension} from "src/ModularExtension.sol";
import {ModularCore} from "src/ModularCore.sol";
import {ERC20Core} from "src/core/token/ERC20Core.sol";
import {MintableERC20, MintableStorage} from "src/extension/token/minting/MintableERC20.sol";
import {Role} from "src/Role.sol";

contract MockCurrency is ERC20 {
    function mintTo(address _recipient, uint256 _amount) public {
        _mint(_recipient, _amount);
    }

    /// @dev Returns the name of the token.
    function name() public view virtual override returns (string memory) {
        return "MockCurrency";
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view virtual override returns (string memory) {
        return "MOCK";
    }
}

contract MintableERC20Test is Test {
    ERC20Core public core;

    MintableERC20 public extensionImplementation;
    MintableERC20 public installedExtension;

    uint256 ownerPrivateKey = 1;
    address public owner;

    uint256 public permissionedActorPrivateKey = 2;
    address public permissionedActor;

    uint256 unpermissionedActorPrivateKey = 3;
    address public unpermissionedActor;

    address tokenRecipient = address(0x123);

    // Signature vars
    bytes32 internal typehashMintRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;

    MintableERC20.MintRequestERC20 public mintRequest;

    // Constants
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Util fn
    function signMintRequest(MintableERC20.MintRequestERC20 memory _req, uint256 _privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes memory encodedRequest = abi.encode(
            typehashMintRequest,
            _req.startTimestamp,
            _req.endTimestamp,
            _req.recipient,
            _req.quantity,
            _req.currency,
            _req.pricePerUnit,
            _req.uid
        );
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, typedDataHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        return sig;
    }

    function setUp() public {
        owner = vm.addr(ownerPrivateKey);
        permissionedActor = vm.addr(permissionedActorPrivateKey);
        unpermissionedActor = vm.addr(unpermissionedActorPrivateKey);

        address[] memory extensions;
        bytes[] memory extensionData;

        core = new ERC20Core("test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new MintableERC20();

        // install extension
        bytes memory encodedInstallParams = abi.encode(owner);
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), encodedInstallParams);

        // Setup signature vars
        typehashMintRequest = keccak256(
            "MintRequestERC20(uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,bytes32 uid)"
        );
        nameHash = keccak256(bytes("MintableERC20"));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(core)));

        // Give permissioned actor minter role
        vm.prank(owner);
        core.grantRoles(permissionedActor, Role._MINTER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: get / set SaleConfig
    //////////////////////////////////////////////////////////////*/

    function test_saleConfig_state() public {
        address saleRecipient = address(0x123);

        vm.prank(owner);
        MintableERC20(address(core)).setSaleConfig(saleRecipient);

        address recipient = MintableERC20(address(core)).getSaleConfig();

        assertEq(recipient, saleRecipient);
    }

    function test_setSaleConfig_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        MintableERC20(address(core)).setSaleConfig(address(0x123));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: beforeMintERC20
    //////////////////////////////////////////////////////////////*/

    function test_mint_state() public {
        address saleRecipient = address(0x987);

        vm.prank(owner);
        MintableERC20(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );

        // Check minted balance
        assertEq(core.balanceOf(address(0x123)), 100 ether);

        uint256 salePrice = (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether;
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_revert_unableToDecodeArgs() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert();
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(bytes("random mixer"), params)
        );
    }

    function test_mint_revert_requestInvalidRecipient() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestMismatch.selector));
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            address(0x456), // recipient mismatch
            mintRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidAmount() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestMismatch.selector));
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient,
            mintRequest.quantity - 1, // quantity mismatch
            abi.encode(params)
        );
    }

    function test_mint_revert_requestBeforeValidityStart() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp + 100), // tx before validity start
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestAfterValidityEnd() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.warp(mintRequest.endTimestamp);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestUidReused() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
        assertEq(core.balanceOf(mintRequest.recipient), mintRequest.quantity);

        MintableERC20.MintRequestERC20 memory mintRequestTwo = mintRequest;
        mintRequestTwo.recipient = address(0x786);
        mintRequestTwo.pricePerUnit = 0;

        bytes memory sigTwo = signMintRequest(mintRequestTwo, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory paramsTwo = MintableERC20.MintParamsERC20(mintRequestTwo, sigTwo);

        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestUidReused.selector));
        core.mint(mintRequestTwo.recipient, mintRequestTwo.quantity, abi.encode(paramsTwo));
    }

    function test_mint_revert_requestUnauthorizedSigner() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, ownerPrivateKey); // is owner but not MINTER_ROLE holder

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableRequestUnauthorized.selector));
        core.mint{value: (mintRequest.quantity * mintRequest.pricePerUnit) / 1 ether}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_noPriceButNativeTokensSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_incorrectNativeTokenSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC20.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_insufficientERC20CurrencyBalance() public {
        MockCurrency currency = new MockCurrency();

        assertEq(currency.balanceOf(tokenRecipient), 0);

        MintableERC20.MintRequestERC20 memory mintRequest = MintableERC20.MintRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(currency),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC20.MintParamsERC20 memory params = MintableERC20.MintParamsERC20(mintRequest, sig);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(0x7939f424)); // TransferFromFailed()
        core.mint(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }
}
