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
import {ERC721Core} from "src/core/token/ERC721Core.sol";
import {MintableERC721, MintableStorage} from "src/extension/token/minting/MintableERC721.sol";
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

contract MintableERC721Test is Test {
    ERC721Core public core;

    MintableERC721 public extensionImplementation;
    MintableERC721 public installedExtension;

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

    MintableERC721.MintRequestERC721 public mintRequest;

    // Constants
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Util fn
    function signMintRequest(MintableERC721.MintRequestERC721 memory _req, uint256 _privateKey)
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
            keccak256(bytes(_req.baseURI)),
            _req.uid
        );
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, typedDataHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        return sig;
    }

    function _hashMetadataURIs(string[] memory metadataURIs) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](metadataURIs.length);

        for (uint256 i = 0; i < metadataURIs.length; i++) {
            hashes[i] = keccak256(bytes(metadataURIs[i]));
        }

        return keccak256(abi.encodePacked(hashes));
    }

    function getMetadataURIs(uint256 _num) internal pure returns (string[] memory) {
        string[] memory metadataURIs = new string[](_num);
        for (uint256 i = 0; i < _num; i++) {
            metadataURIs[i] = "https://example.com";
        }
        return metadataURIs;
    }

    function setUp() public {
        owner = vm.addr(ownerPrivateKey);
        permissionedActor = vm.addr(permissionedActorPrivateKey);
        unpermissionedActor = vm.addr(unpermissionedActorPrivateKey);

        address[] memory extensions;
        bytes[] memory extensionData;

        core = new ERC721Core("test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new MintableERC721();

        // install extension
        bytes memory encodedInstallParams = abi.encode(owner);
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), encodedInstallParams);

        // Setup signature vars
        typehashMintRequest = keccak256(
            "MintRequestERC721(uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,string baseURI,bytes32 uid)"
        );
        nameHash = keccak256(bytes("MintableERC721"));
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
        MintableERC721(address(core)).setSaleConfig(saleRecipient);

        address recipient = MintableERC721(address(core)).getSaleConfig();

        assertEq(recipient, saleRecipient);
    }

    function test_setSaleConfig_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        MintableERC721(address(core)).setSaleConfig(address(0x123));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: beforeMintERC721
    //////////////////////////////////////////////////////////////*/

    function test_mint_state() public {
        address saleRecipient = address(0x987);

        vm.prank(owner);
        MintableERC721(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );

        assertEq(core.tokenURI(0), "https://example.com/0");

        // Check minted balance
        assertEq(core.balanceOf(address(0x123)), mintRequest.quantity);

        uint256 salePrice = mintRequest.quantity * mintRequest.pricePerUnit;
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_revert_unableToDecodeArgs() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert();
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(bytes("random mixer"), params)
        );
    }

    function test_mint_revert_requestInvalidRecipient() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            address(0x456), // recipient mismatch
            mintRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidMetadataURIs() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            address(0x456), // recipient mismatch
            mintRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidAmount() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestMismatch.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient,
            mintRequest.quantity - 1, // quantity mismatch
            abi.encode(params)
        );
    }

    function test_mint_revert_requestBeforeValidityStart() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp + 100), // tx before validity start
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestAfterValidityEnd() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.warp(mintRequest.endTimestamp);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestOutOfTimeWindow.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestUidReused() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
        assertEq(core.balanceOf(mintRequest.recipient), mintRequest.quantity);

        MintableERC721.MintRequestERC721 memory mintRequestTwo = mintRequest;
        mintRequestTwo.recipient = address(0x786);
        mintRequestTwo.pricePerUnit = 0;

        bytes memory sigTwo = signMintRequest(mintRequestTwo, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory paramsTwo = MintableERC721.MintParamsERC721(mintRequestTwo, sigTwo, "");

        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestUidReused.selector));
        core.mint(mintRequestTwo.recipient, mintRequestTwo.quantity, abi.encode(paramsTwo));
    }

    function test_mint_revert_requestUnauthorizedSigner() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, ownerPrivateKey); // is owner but not MINTER_ROLE holder

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableRequestUnauthorized.selector));
        core.mint{value: mintRequest.quantity * mintRequest.pricePerUnit}(
            mintRequest.recipient, mintRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_noPriceButNativeTokensSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_incorrectNativeTokenSent() public {
        vm.deal(tokenRecipient, 100 ether);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 1,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(MintableERC721.MintableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_insufficientERC721CurrencyBalance() public {
        MockCurrency currency = new MockCurrency();

        assertEq(currency.balanceOf(tokenRecipient), 0);

        MintableERC721.MintRequestERC721 memory mintRequest = MintableERC721.MintRequestERC721({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 1,
            currency: address(currency),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            baseURI: "https://example.com/"
        });
        bytes memory sig = signMintRequest(mintRequest, permissionedActorPrivateKey);

        MintableERC721.MintParamsERC721 memory params = MintableERC721.MintParamsERC721(mintRequest, sig, "");

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(0x7939f424)); // TransferFromFailed()
        core.mint(mintRequest.recipient, mintRequest.quantity, abi.encode(params));
    }
}
