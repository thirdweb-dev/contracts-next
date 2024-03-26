// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { Merkle } from "@murky/Merkle.sol";
import "forge-std/console2.sol";

import { MockERC20 } from "test/mocks/MockERC20.sol";
import { CloneFactory } from "src/infra/CloneFactory.sol";
import { EIP1967Proxy } from "src/infra/EIP1967Proxy.sol";

import { IHook } from "src/interface/hook/IHook.sol";

import { ERC1155Core, HookInstaller } from "src/core/token/ERC1155Core.sol";
import { BurnHookERC1155, ERC1155Hook } from "src/hook/burn/BurnHookERC1155.sol";

import { EmptyHookERC1155 } from "../mocks/EmptyHook.sol";

import { IBurnRequest } from "src/interface/common/IBurnRequest.sol";

import { IClaimCondition } from "src/interface/common/IClaimCondition.sol";
import { IFeeConfig } from "src/interface/common/IFeeConfig.sol";

contract BurnHookERC1155Test is Test {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Participants
    address public platformAdmin = address(0x123);

    uint256 developerPKey = 100;
    address public developer;

    address public endUser = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;

    // Target test contracts
    ERC1155Core public erc1155Core;
    BurnHookERC1155 public BurnHook;
    EmptyHookERC1155 public MintHook;

    // Test params
    uint256 public constant BEFORE_BURN_FLAG = 2 ** 3;
    bytes32 private constant TYPEHASH =
        keccak256(
            "BurnRequest(address token,uint256 tokenId,address owner,uint256 quantity,bytes permissionSignature,uint128 sigValidityStartTimestamp,uint128 sigValidityEndTimestamp,bytes32 sigUid)"
        );
    bytes32 public domainSeparator;

    bytes32 public allowlistRoot;
    bytes32[] public allowlistProof;

    function _setupDomainSeparator(address _BurnHook) internal {
        bytes32 nameHash = keccak256(bytes("BurnHookERC1155"));
        bytes32 versionHash = keccak256(bytes("1"));
        bytes32 typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, _BurnHook));
    }

    function setUp() public {
        developer = vm.addr(developerPKey);

        // Platform deploys burn hook.
        vm.startPrank(platformAdmin);

        address BurnHookImpl = address(new BurnHookERC1155());

        bytes memory initData = abi.encodeWithSelector(
            BurnHookERC1155.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address BurnHookProxy = address(new EIP1967Proxy(BurnHookImpl, initData));
        BurnHook = BurnHookERC1155(BurnHookProxy);

        // Set up empty mint hook for minting as its required by the ERC1155Core
        address EmptyHookImpl = address(new EmptyHookERC1155());

        bytes memory emptyHookInitData = abi.encodeWithSelector(
            EmptyHookERC1155.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address EmptyHookProxy = address(new EIP1967Proxy(EmptyHookImpl, emptyHookInitData));
        MintHook = EmptyHookERC1155(EmptyHookProxy);

        // Platform deploys ERC1155 core implementation and clone factory.
        address erc1155CoreImpl = address(new ERC1155Core());
        CloneFactory factory = new CloneFactory();

        vm.stopPrank();

        // Setup domain separator of burn hook for signature burning.
        _setupDomainSeparator(BurnHookProxy);

        // Developer deploys proxy for ERC1155 core with BurnHookERC1155 preinstalled.
        vm.startPrank(developer);

        ERC1155Core.InitCall memory initCall;
        address[] memory preinstallHooks = new address[](2);
        preinstallHooks[0] = address(MintHook);
        preinstallHooks[1] = address(BurnHook);

        bytes memory erc1155InitData = abi.encodeWithSelector(
            ERC1155Core.initialize.selector,
            initCall,
            preinstallHooks,
            developer, // core contract admin
            "Test ERC1155",
            "TST",
            "ipfs://QmPVMvePSWfYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/0" // mock contract URI of actual length
        );
        erc1155Core = ERC1155Core(
            factory.deployProxyByImplementation(erc1155CoreImpl, erc1155InitData, bytes32("salt"))
        );

        vm.stopPrank();


        // Set labels
        vm.deal(endUser, 100 ether);

        vm.label(platformAdmin, "Admin");
        vm.label(developer, "Developer");
        vm.label(endUser, "Claimer");

        vm.label(address(erc1155Core), "ERC1155Core");
        vm.label(address(BurnHookImpl), "BurnHookERC1155");
        vm.label(BurnHookProxy, "ProxyBurnHookERC1155");

        // Log for the storage slot of BurnHookERC1155 (for the storage location file BurnHookERC1155Storage.sol)
        bytes32 storageSlot = keccak256(abi.encode(uint256(keccak256("burn.hook.erc1155.storage")) - 1)) & ~bytes32(uint256(0xff));
        console2.logBytes32( storageSlot);
    }

    function _signBurnRequest(
        IBurnRequest.BurnRequest memory _req,
        uint256 _privateKey
    ) internal view returns (bytes memory) {
        bytes memory encodedRequest = abi.encode(
            TYPEHASH,
            _req.token,
            _req.tokenId,
            _req.owner,
            _req.quantity,
            keccak256(bytes("")),
            _req.sigValidityStartTimestamp,
            _req.sigValidityEndTimestamp,
            _req.sigUid
        );
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, typedDataHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        return sig;
    }

    function mintForAddress(address _to, uint256 _id, uint256 _quantity) internal {
        vm.prank(_to);
        erc1155Core.mint(address(_to), _id, _quantity, "");
        vm.stopPrank();
    }

    function test_beforeBurn_mintTokenToUser_success() public {   
        mintForAddress(endUser, 1337, 1);
        assertEq(erc1155Core.balanceOf(address(endUser), 1337), 1);
        assertEq(erc1155Core.totalSupply(1337),1);

    }
    
    function test_beforeBurn_successfulBurnCase() public {
        //TokenId
        uint256 tokenId = 1337;
        // Minting 1 token to endUser
        mintForAddress(endUser, tokenId, 1);
        assertEq(erc1155Core.balanceOf(address(endUser), tokenId), 1);

        // Create request with happy path signature
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        assertEq(erc1155Core.balanceOf(endUser, tokenId), 1);
        assertEq(erc1155Core.totalSupply(tokenId), 1);

        // Burn the token
        vm.prank(endUser);
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));

        assertEq(erc1155Core.balanceOf(endUser, tokenId), 0);
        assertEq(erc1155Core.totalSupply(tokenId), 0); 
    }

    function test_beforeBurn_revert_burnHookNotToken() public {
       uint256 tokenId = 1337;
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(0x999), // use not the token address
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookNotToken.selector));
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
    }

    function test_beforeBurn_revert_burnHookInvalidQuantity() public {
        uint256 tokenId = 1337;
        uint256 quantityInReqest = 1;
        uint256 invalidQuantity = 2;
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: quantityInReqest, // use different quantity
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookInvalidQuantity.selector, 2));
        // Burn the token with different quantity
        erc1155Core.burn(req.owner, req.tokenId, invalidQuantity, abi.encode(req));
    }

    function test_beforeBurn_revert_burnHookInvalidRecipient() public {
        uint256 tokenId = 1337;
        address invalidOwner = address(0x999);
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookInvalidRecipient.selector));
        // Burn the token with different owner
        erc1155Core.burn(invalidOwner, req.tokenId, req.quantity, abi.encode(req));
    }

    function test_beforeBurn_revert_permissionlessBurn_invalidTokenId() public {
        uint256 tokenId = 1337;
        uint256 invalidTokenId = 1338;

        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId, // use different token id
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookInvalidTokenId.selector, invalidTokenId));
        // Burn the token with different token id
        erc1155Core.burn(req.owner, invalidTokenId, req.quantity, abi.encode(req));
    }

    function test_beforeBurn_revert_burnHookInvalidSignature() public {
        uint256 tokenId = 1337;
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0), // use empty signature and don't replace below
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookInvalidSignature.selector));
        // Burn the token with invalid signature
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
    }

    function test_beforeBurn_revert_burnHookRequestExpired() public {
        uint256 tokenId = 1337;
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 0, // use expired signature
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookRequestExpired.selector));
        // Burn the token with expired signature
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
    }

    function test_beforeBurn_revert_burnHookRequestUsed() public {
        uint256 tokenId = 1337;
        // Minting 1 token to endUser so that first burn can be successful
        mintForAddress(endUser, tokenId, 1);
        assertEq(erc1155Core.balanceOf(address(endUser), tokenId), 1);

        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, developerPKey);
        req.permissionSignature = sig;

        // Burn the token
        vm.prank(endUser);
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
        vm.stopPrank();

        // Burn the token with the same signature
        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookRequestUsed.selector));
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
    }

    function test_verifyPermissionClaim_revert_burnHookInvalidSignature() public {
        uint256 tokenId = 1337;
        // Create burn request
        IBurnRequest.BurnRequest memory req = IBurnRequest.BurnRequest({
            token: address(erc1155Core),
            tokenId: tokenId,
            owner: endUser,
            quantity: 1,
            permissionSignature: new bytes(0),
            sigValidityStartTimestamp: 0,
            sigValidityEndTimestamp: 200,
            sigUid: bytes32("random-1")
        });

        bytes memory sig = _signBurnRequest(req, 0x999); // use different private key
        req.permissionSignature = sig;

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(BurnHookERC1155.BurnHookInvalidSignature.selector));
        // Burn the token with invalid signature
        erc1155Core.burn(req.owner, req.tokenId, req.quantity, abi.encode(req));
    }
}
