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
import {ClaimableERC1155, ClaimableStorage} from "src/extension/token/minting/ClaimableERC1155.sol";
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

contract ClaimableERC1155Test is Test {
    ERC1155Core public core;

    ClaimableERC1155 public extensionImplementation;
    ClaimableERC1155 public installedExtension;

    uint256 ownerPrivateKey = 1;
    address public owner;

    uint256 public permissionedActorPrivateKey = 2;
    address public permissionedActor;

    uint256 unpermissionedActorPrivateKey = 3;
    address public unpermissionedActor;

    address tokenRecipient = address(0x123);

    // Signature vars
    bytes32 internal typehashClaimRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;

    ClaimableERC1155.ClaimRequestERC1155 public claimRequest;
    ClaimableERC1155.ClaimCondition public claimCondition;

    // Constants
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Util fn
    function signMintRequest(ClaimableERC1155.ClaimRequestERC1155 memory _req, uint256 _privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes memory encodedRequest = abi.encode(
            typehashClaimRequest,
            _req.tokenId,
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

        core = new ERC1155Core("test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new ClaimableERC1155();

        // install extension
        bytes memory encodedInstallParams = abi.encode(owner);
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), encodedInstallParams);

        // Setup signature vars
        typehashClaimRequest = keccak256(
            "ClaimRequestERC1155(uint256 tokenId,uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,bytes32 uid)"
        );
        nameHash = keccak256(bytes("ClaimableERC1155"));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(core)));

        // Give permissioned actor minter role
        vm.prank(owner);
        core.grantRoles(permissionedActor, Role._MINTER_ROLE);
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: get / set Claim Condition
    //////////////////////////////////////////////////////////////*/

    function test_setClaimCondition_state() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        ClaimableERC1155.ClaimCondition memory storedCondition =
            ClaimableERC1155(address(core)).getClaimConditionByTokenId(0);

        assertEq(storedCondition.availableSupply, condition.availableSupply);
        assertEq(storedCondition.pricePerUnit, condition.pricePerUnit);
        assertEq(storedCondition.currency, condition.currency);
        assertEq(storedCondition.startTimestamp, condition.startTimestamp);
        assertEq(storedCondition.endTimestamp, condition.endTimestamp);
        assertEq(storedCondition.auxData, condition.auxData);
    }

    function test_setClaimCondition_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(
            0,
            ClaimableERC1155.ClaimCondition({
                availableSupply: 100 ether,
                pricePerUnit: 0.1 ether,
                currency: NATIVE_TOKEN_ADDRESS,
                startTimestamp: uint48(block.timestamp),
                endTimestamp: uint48(block.timestamp + 100),
                auxData: "",
                allowlistMerkleRoot: bytes32(0)
            })
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: get / set SaleConfig
    //////////////////////////////////////////////////////////////*/

    function test_saleConfig_state() public {
        address saleRecipient = address(0x123);

        vm.prank(owner);
        ClaimableERC1155(address(core)).setSaleConfig(saleRecipient);

        address recipient = ClaimableERC1155(address(core)).getSaleConfig();

        assertEq(recipient, saleRecipient);
    }

    function test_setSaleConfig_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        ClaimableERC1155(address(core)).setSaleConfig(address(0x123));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: beforeMintERC1155
    //////////////////////////////////////////////////////////////*/

    function test_mint_state() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC1155(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );

        // Check minted balance
        assertEq(core.balanceOf(address(0x123), 0), 100);

        uint256 salePrice = (claimRequest.quantity * claimRequest.pricePerUnit);
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_state_overridePrice() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.1 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC1155(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.2 ether, // different price from condition
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );

        // Check minted balance
        assertEq(core.balanceOf(address(0x123), 0), 100);

        uint256 salePrice = (claimRequest.quantity * claimRequest.pricePerUnit);
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_state_overrideCurrency() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.1 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC1155(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(currency), // different currency from condition
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        currency.mintTo(tokenRecipient, 100 ether);

        uint256 balBefore = currency.balanceOf(tokenRecipient);
        assertEq(balBefore, 100 ether);
        assertEq(currency.balanceOf(saleRecipient), 0);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );

        uint256 salePrice = (claimRequest.quantity * condition.pricePerUnit);

        vm.prank(tokenRecipient);
        currency.approve(address(core), salePrice);

        vm.prank(tokenRecipient);
        core.mint(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));

        // Check minted balance
        assertEq(core.balanceOf(address(0x123), 0), 100);

        assertEq(currency.balanceOf(tokenRecipient), balBefore - salePrice);
        assertEq(currency.balanceOf(saleRecipient), salePrice);
    }

    function test_mint_revert_unableToDecodeArgs() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert();
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(bytes("random mixer"), params)
        );
    }

    function test_mint_revert_requestInvalidRecipient() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestMismatch.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            address(0x456), // recipient mismatch
            0,
            claimRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidAmount() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestMismatch.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient,
            0,
            claimRequest.quantity - 1, // quantity mismatch
            abi.encode(params)
        );
    }

    function test_mint_revert_requestBeforeValidityStart() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp + 100), // tx before validity start
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestOutOfTimeWindow.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestAfterValidityEnd() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.warp(claimRequest.endTimestamp);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestOutOfTimeWindow.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestUidReused() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );
        assertEq(core.balanceOf(claimRequest.recipient, 0), claimRequest.quantity);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequestTwo = claimRequest;
        claimRequestTwo.recipient = address(0x786);
        claimRequestTwo.pricePerUnit = 0;

        bytes memory sigTwo = signMintRequest(claimRequestTwo, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory paramsTwo =
            ClaimableERC1155.ClaimParamsERC1155(claimRequestTwo, sigTwo, address(0), 0, new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestUidReused.selector));
        core.mint(claimRequestTwo.recipient, 0, claimRequestTwo.quantity, abi.encode(paramsTwo));
    }

    function test_mint_revert_requestUnauthorizedSigner() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, ownerPrivateKey); // is owner but not MINTER_ROLE holder

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableRequestUnauthorizedSignature.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit)}(
            claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_noPriceButNativeTokensSent() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_incorrectNativeTokenSent() public {
        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: 5 ether}(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_insufficientERC1155CurrencyBalance() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: address(0),
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        assertEq(currency.balanceOf(tokenRecipient), 0);

        ClaimableERC1155.ClaimRequestERC1155 memory claimRequest = ClaimableERC1155.ClaimRequestERC1155({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100,
            currency: address(currency),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1"),
            tokenId: 0
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC1155.ClaimParamsERC1155 memory params =
            ClaimableERC1155.ClaimParamsERC1155(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(0x7939f424)); // TransferFromFailed()
        core.mint(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_unexpectedPriceOrCurrency() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC1155.ClaimCondition memory condition = ClaimableERC1155.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC1155(address(core)).setClaimConditionByTokenId(0, condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC1155(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC1155.ClaimParamsERC1155 memory params = ClaimableERC1155.ClaimParamsERC1155(
            claimRequest, "", address(currency), condition.pricePerUnit, new bytes32[](0)
        ); // unexpected currrency

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectPriceOrCurrency.selector));
        core.mint(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));

        params.currency = NATIVE_TOKEN_ADDRESS;
        params.pricePerUnit = 0.1 ether; // unexpected price

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC1155.ClaimableIncorrectPriceOrCurrency.selector));
        core.mint(claimRequest.recipient, 0, claimRequest.quantity, abi.encode(params));
    }
}
