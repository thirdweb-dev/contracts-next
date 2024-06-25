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
import {ClaimableERC20, ClaimableStorage} from "src/extension/token/minting/ClaimableERC20.sol";
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

contract ClaimableERC20Test is Test {
    ERC20Core public core;

    ClaimableERC20 public extensionImplementation;
    ClaimableERC20 public installedExtension;

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

    ClaimableERC20.ClaimRequestERC20 public claimRequest;
    ClaimableERC20.ClaimCondition public claimCondition;

    // Constants
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Util fn
    function signMintRequest(ClaimableERC20.ClaimRequestERC20 memory _req, uint256 _privateKey)
        internal
        view
        returns (bytes memory)
    {
        bytes memory encodedRequest = abi.encode(
            typehashClaimRequest,
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
        extensionImplementation = new ClaimableERC20();

        // install extension
        bytes memory encodedInstallParams = abi.encode(owner);
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), encodedInstallParams);

        // Setup signature vars
        typehashClaimRequest = keccak256(
            "ClaimRequestERC20(uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,bytes32 uid)"
        );
        nameHash = keccak256(bytes("ClaimableERC20"));
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

    function test_claimCondition_state() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        ClaimableERC20.ClaimCondition memory storedCondition = ClaimableERC20(address(core)).getClaimCondition();

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
        ClaimableERC20(address(core)).setClaimCondition(
            ClaimableERC20.ClaimCondition({
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
        ClaimableERC20(address(core)).setSaleConfig(saleRecipient);

        address recipient = ClaimableERC20(address(core)).getSaleConfig();

        assertEq(recipient, saleRecipient);
    }

    function test_setSaleConfig_revert_unauthorizedCaller() public {
        vm.prank(unpermissionedActor);
        vm.expectRevert(abi.encodeWithSelector(0x82b42900)); // Unauthorized()
        ClaimableERC20(address(core)).setSaleConfig(address(0x123));
    }

    /*//////////////////////////////////////////////////////////////
                        Tests: beforeMintERC20
    //////////////////////////////////////////////////////////////*/

    function test_mint_state() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC20(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );

        // Check minted balance
        assertEq(core.balanceOf(address(0x123)), 100 ether);

        uint256 salePrice = (claimRequest.quantity * claimRequest.pricePerUnit) / 1 ether;
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_state_overridePrice() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.1 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC20(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.2 ether, // different price from condition
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        uint256 balBefore = tokenRecipient.balance;
        assertEq(balBefore, 100 ether);
        assertEq(saleRecipient.balance, 0);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );

        // Check minted balance
        assertEq(core.balanceOf(address(0x123)), 100 ether);

        uint256 salePrice = (claimRequest.quantity * claimRequest.pricePerUnit) / 1 ether;
        assertEq(tokenRecipient.balance, balBefore - salePrice);
        assertEq(saleRecipient.balance, salePrice);
    }

    function test_mint_state_overrideCurrency() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.1 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC20(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(currency), // different currency from condition
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        currency.mintTo(tokenRecipient, 100 ether);

        uint256 balBefore = currency.balanceOf(tokenRecipient);
        assertEq(balBefore, 100 ether);
        assertEq(currency.balanceOf(saleRecipient), 0);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );

        uint256 salePrice = (claimRequest.quantity * condition.pricePerUnit) / 1 ether;

        vm.prank(tokenRecipient);
        currency.approve(address(core), salePrice);

        vm.prank(tokenRecipient);
        core.mint(claimRequest.recipient, claimRequest.quantity, abi.encode(params));

        // Check minted balance
        assertEq(core.balanceOf(address(0x123)), 100 ether);

        assertEq(currency.balanceOf(tokenRecipient), balBefore - salePrice);
        assertEq(currency.balanceOf(saleRecipient), salePrice);
    }

    function test_mint_revert_unableToDecodeArgs() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert();
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(bytes("random mixer"), params)
        );
    }

    function test_mint_revert_requestInvalidRecipient() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestMismatch.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            address(0x456), // recipient mismatch
            claimRequest.quantity,
            abi.encode(params)
        );
    }

    function test_mint_revert_requestInvalidAmount() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestMismatch.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient,
            claimRequest.quantity - 1, // quantity mismatch
            abi.encode(params)
        );
    }

    function test_mint_revert_requestBeforeValidityStart() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp + 100), // tx before validity start
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestOutOfTimeWindow.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestAfterValidityEnd() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.warp(claimRequest.endTimestamp);

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestOutOfTimeWindow.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_requestUidReused() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200), // tx at / after validity end
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        core.mint{value: (claimRequest.quantity * claimRequest.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );
        assertEq(core.balanceOf(claimRequest.recipient), claimRequest.quantity);

        ClaimableERC20.ClaimRequestERC20 memory claimRequestTwo = claimRequest;
        claimRequestTwo.recipient = address(0x786);
        claimRequestTwo.pricePerUnit = 0;

        bytes memory sigTwo = signMintRequest(claimRequestTwo, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory paramsTwo =
            ClaimableERC20.ClaimParamsERC20(claimRequestTwo, sigTwo, address(0), 0, new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestUidReused.selector));
        core.mint(claimRequestTwo.recipient, claimRequestTwo.quantity, abi.encode(paramsTwo));
    }

    function test_mint_revert_requestUnauthorizedSigner() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(0),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, ownerPrivateKey); // is owner but not MINTER_ROLE holder

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableRequestUnauthorizedSignature.selector));
        core.mint{value: (claimRequest.quantity * condition.pricePerUnit) / 1 ether}(
            claimRequest.recipient, claimRequest.quantity, abi.encode(params)
        );
    }

    function test_mint_revert_noPriceButNativeTokensSent() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: 1 ether}(claimRequest.recipient, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_incorrectNativeTokenSent() public {
        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectNativeTokenSent.selector));
        core.mint{value: 5 ether}(claimRequest.recipient, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_insufficientERC20CurrencyBalance() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: address(0),
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        assertEq(currency.balanceOf(tokenRecipient), 0);

        ClaimableERC20.ClaimRequestERC20 memory claimRequest = ClaimableERC20.ClaimRequestERC20({
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 200),
            recipient: tokenRecipient,
            quantity: 100 ether,
            currency: address(currency),
            pricePerUnit: 0.1 ether,
            uid: bytes32("1")
        });
        bytes memory sig = signMintRequest(claimRequest, permissionedActorPrivateKey);

        ClaimableERC20.ClaimParamsERC20 memory params =
            ClaimableERC20.ClaimParamsERC20(claimRequest, sig, address(0), 0, new bytes32[](0));

        vm.prank(tokenRecipient);
        vm.expectRevert(abi.encodeWithSelector(0x7939f424)); // TransferFromFailed()
        core.mint(claimRequest.recipient, claimRequest.quantity, abi.encode(params));
    }

    function test_mint_revert_unexpectedPriceOrCurrency() public {
        MockCurrency currency = new MockCurrency();

        ClaimableERC20.ClaimCondition memory condition = ClaimableERC20.ClaimCondition({
            availableSupply: 1000 ether,
            pricePerUnit: 0.2 ether,
            currency: NATIVE_TOKEN_ADDRESS,
            startTimestamp: uint48(block.timestamp),
            endTimestamp: uint48(block.timestamp + 100),
            auxData: "",
            allowlistMerkleRoot: bytes32(0)
        });

        vm.prank(owner);
        ClaimableERC20(address(core)).setClaimCondition(condition);

        address saleRecipient = address(0x987);

        vm.prank(owner);
        ClaimableERC20(address(core)).setSaleConfig(saleRecipient);

        vm.deal(tokenRecipient, 100 ether);

        ClaimableERC20.ClaimParamsERC20 memory params = ClaimableERC20.ClaimParamsERC20(
            claimRequest, "", address(currency), condition.pricePerUnit, new bytes32[](0)
        ); // unexpected currrency

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectPriceOrCurrency.selector));
        core.mint(claimRequest.recipient, claimRequest.quantity, abi.encode(params));

        params.currency = NATIVE_TOKEN_ADDRESS;
        params.pricePerUnit = 0.1 ether; // unexpected price

        vm.expectRevert(abi.encodeWithSelector(ClaimableERC20.ClaimableIncorrectPriceOrCurrency.selector));
        core.mint(claimRequest.recipient, claimRequest.quantity, abi.encode(params));
    }
}
