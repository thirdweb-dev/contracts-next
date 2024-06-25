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
import {ERC1155Core} from "src/core/token/ERC1155Core.sol";
import {MintableERC1155, MintableStorage} from "src/extension/token/minting/MintableERC1155.sol";
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

contract MintableERC1155Test is Test {
    ERC1155Core public core;

    MintableERC1155 public extensionImplementation;
    MintableERC1155 public installedExtension;

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

    MintableERC1155.MintRequestERC1155 public mintRequest;

    // Constants
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Util fn
    function signMintRequest(MintableERC1155.MintRequestERC1155 memory _req, uint256 _privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes memory encodedRequest = abi.encode(
            typehashMintRequest,
            _req.tokenId,
            _req.startTimestamp,
            _req.endTimestamp,
            _req.recipient,
            _req.quantity,
            _req.currency,
            _req.pricePerUnit,
            keccak256(bytes(_req.metadataURI)),
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

        core = new ERC1155Core("test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new MintableERC1155();

        // install extension
        bytes memory encodedInstallParams = abi.encode(owner);
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), encodedInstallParams);

        // Setup signature vars
        typehashMintRequest = keccak256(
            "MintRequestERC1155(uint256 tokenId,uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,string metadataURI,bytes32 uid)"
        );
        nameHash = keccak256(bytes("MintableERC1155"));
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
        MintableERC1155(address(core)).setSaleConfig(saleRecipient);

        address recipient = MintableERC1155(address(core)).getSaleConfig();

        assertEq(recipient, saleRecipient);
    }

    function test_setSaleConfig_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        MintableERC1155(address(core)).setSaleConfig(address(0x123));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: beforeMintERC1155
    //////////////////////////////////////////////////////////////*/

    function test_mint_state() public {
        address saleRecipient = address(0x987);

        vm.prank(owner);
        MintableERC1155(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params)
        );

        assertEq(core.uri(0), "https://example.com");

        // Check minted balance
        assertEq(core.balanceOf(address(0x123), mintRequest.tokenId), mintRequest.quantity);

        uint256 salePrice = mintRequest.quantity * mintRequest.pricePerUnit;
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_revert_unableToDecodeArgs() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert();
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(bytes("random mixer"), params)
        );
    }

    function test_mint_revert_requestInvalidRecipient() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            address(0x456), // recipient mismatch
            mintRequest.tokenId,
            mintRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidTokenId() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 1, // incorrect token ID
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            address(0x456), // recipient mismatch
            mintRequest.tokenId,
            mintRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidAmount() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient,
            mintRequest.tokenId,
            mintRequest.quantity - 1, // quantity mismatch
            abi.encode(params)
        );
    }

    function test_mint_revert_requestBeforeValidityStart() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp + 100), // tx before validity start
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestAfterValidityEnd() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.warp(mintRequest.endTimestamp);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestUidReused() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params)
        );
        assertEq(core.balanceOf(mintRequest.recipient, mintRequest.tokenId), mintRequest.quantity);

        MintableERC1155.MintRequestERC1155 memory mintRequestTwo = mintRequest;
        mintRequestTwo.recipient = address(0x786);
        mintRequestTwo.pricePerUnit = 0;

        bytes memory sigTwo = signMintRequest(mintRequestTwo, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory paramsTwo =
            MintableERC1155.MintParamsERC1155(mintRequestTwo, sigTwo, "");

        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestUidReused.selector));
        core.mint(mintRequestTwo.recipient, mintRequestTwo.tokenId, mintRequestTwo.quantity, abi.encode(paramsTwo));
    }

    function test_mint_revert_requestUnauthorizedSigner() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, ownerPrivateKey); // is owner but not MINTER_ROLE holder

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableRequestUnauthorized.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_noPriceButNativeTokensSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_incorrectNativeTokenSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC1155.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_insufficientERC1155CurrencyBalance() public {
        MockCurrency currency = new MockCurrency();

        assertEq(currency.balanceOf(tokenRecipient), 0);

        MintableERC1155.MintRequestERC1155 memory mintRequest = MintableERC1155.MintRequestERC1155({
            tokenId: 0,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(currency),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            metadataURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC1155.MintParamsERC1155 memory params = MintableERC1155.MintParamsERC1155(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(0x7939f424)); // TransferFromFailed()
        core.mint(mintRequest.recipient, mintRequest.tokenId, mintRequest.quantity, abi.encode(params));
    }
}
