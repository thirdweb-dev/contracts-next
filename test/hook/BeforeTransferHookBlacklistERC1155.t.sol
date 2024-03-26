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
import { BlacklistHookERC1155, ERC1155Hook } from "src/hook/beforeTransfer/BlacklistHookERC1155.sol";
import { IBlacklist } from "src/interface/common/IBlacklist.sol";
import { EmptyHookERC1155 } from "../mocks/EmptyHook.sol";

contract MintHookERC1155Test is Test {
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
    BlacklistHookERC1155 public BeforeTransferHook;
    EmptyHookERC1155 public MintHook;

    // Test params
    uint256 public constant BEFORE_TRANSFER_FLAG = 2 ** 2;
 
    function setUp() public {
        developer = vm.addr(developerPKey);

        // Platform deploys burn hook.
        vm.startPrank(platformAdmin);

        address BeforeTransferHookImpl = address(new BlacklistHookERC1155());

        bytes memory initData = abi.encodeWithSelector(
            BeforeTransferHook.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address BeforeTransferHookProxy = address(new EIP1967Proxy(BeforeTransferHookImpl, initData));
        BeforeTransferHook = BlacklistHookERC1155(BeforeTransferHookProxy);

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

        // Developer deploys proxy for ERC1155 core with BurnHookERC1155 preinstalled.
        vm.startPrank(developer);

        ERC1155Core.InitCall memory initCall;
        address[] memory preinstallHooks = new address[](2);
        preinstallHooks[0] = address(MintHook);
        preinstallHooks[1] = address(BeforeTransferHook);

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
        vm.label(address(BeforeTransferHookImpl), "BlackList");
        vm.label(BeforeTransferHookProxy, "ProxyBlackList");

        // Log for the storage slot of Blacklist (for the storage location file BlacklistStorage.sol)
        bytes32 storageSlot = keccak256(abi.encode(uint256(keccak256("blacklist.storage")) - 1)) & ~bytes32(uint256(0xff));
        console2.logBytes32( storageSlot);
    }

    function mintForAddress(address _to, uint256 _id, uint256 _quantity) internal {
        vm.prank(_to);
        erc1155Core.mint(address(_to), _id, _quantity, "");
        vm.stopPrank();
    }

    function checkIfBlacklisted(address _address) internal view returns (bytes memory) {
        return erc1155Core.hookFunctionRead(
            BEFORE_TRANSFER_FLAG,
            abi.encodeWithSelector(BeforeTransferHook.isBlacklisted.selector, _address)
        );
    }

    function test_beforeBurn_mintTokenToUser_success() public {   
        mintForAddress(endUser, 1337, 1);
        assertEq(erc1155Core.balanceOf(address(endUser), 1337), 1);
        assertEq(erc1155Core.totalSupply(1337),1);
    }

    function test_safeTransferFrom_revert_not_authorized() public {
        // Prevent non admin from blacklisting a user
        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(HookInstaller.HookInstallerUnauthorizedWrite.selector));
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistAddress.selector, endUser)
        );
    }

    function test_blacklistAddress_user_success() public {
        // Blacklist a end user from transferring tokens
        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistAddress.selector, endUser)
        );

        bytes memory isBlacklisted = checkIfBlacklisted(endUser);
        assertEq(isBlacklisted, abi.encodePacked(uint256(1)));
    }

    function test_unblacklistAddress_user_success() public {
        // Blacklist
        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistAddress.selector, endUser)
        );

        bytes memory isBlacklisted = checkIfBlacklisted(endUser);
        assertEq(isBlacklisted, abi.encodePacked(uint256(1)));

        vm.prank(developer);
        // Unblacklist 
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.unblacklistAddress.selector, endUser)
        );

        bytes memory isBlacklisted2 = checkIfBlacklisted(endUser);
        assertEq(isBlacklisted2, abi.encodePacked(uint256(0)));
    }
    
    function test_safeTransferFrom_revert_blacklisted() public {
        // Blacklist a end user from transferring tokens
        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistAddress.selector, endUser)
        );

        bytes memory isBlacklisted = checkIfBlacklisted(endUser);
        assertEq(isBlacklisted, abi.encodePacked(uint256(1)));
        vm.stopPrank();

        vm.prank(endUser);
        vm.expectRevert(abi.encodeWithSelector(IBlacklist.AddressIsBlacklisted.selector, endUser, true));
        erc1155Core.safeTransferFrom(address(endUser), address(developer), 1337, 1, "");
    }

   function test_blackListManyAddress_success() public {
        address[] memory addresses = new address[](2);
        addresses[0] = address(0x123);
        addresses[1] = address(0x456);

        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistManyAddress.selector, addresses)
        );

        bytes memory isBlacklisted = checkIfBlacklisted(addresses[0]);
        assertEq(isBlacklisted, abi.encodePacked(uint256(1)));

        bytes memory isBlacklisted2 = checkIfBlacklisted(addresses[1]);
        assertEq(isBlacklisted2, abi.encodePacked(uint256(1)));
    }

    function test_unblacklistManyAddress_success() public {
        address[] memory addresses = new address[](2);
        addresses[0] = address(0x123);
        addresses[1] = address(0x456);

        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.blacklistManyAddress.selector, addresses)
        );

        bytes memory isBlacklisted = checkIfBlacklisted(addresses[0]);
        assertEq(isBlacklisted, abi.encodePacked(uint256(1)));

        bytes memory isBlacklisted2 = checkIfBlacklisted(addresses[1]);
        assertEq(isBlacklisted2, abi.encodePacked(uint256(1)));

        vm.prank(developer);
        erc1155Core.hookFunctionWrite(
            BEFORE_TRANSFER_FLAG,
            0,
            abi.encodeWithSelector(BeforeTransferHook.unblacklistManyAddress.selector, addresses)
        );

        bytes memory isBlacklisted3 = checkIfBlacklisted(addresses[0]);
        assertEq(isBlacklisted3, abi.encodePacked(uint256(0)));

        bytes memory isBlacklisted4 = checkIfBlacklisted(addresses[1]);
        assertEq(isBlacklisted4, abi.encodePacked(uint256(0)));
   }
}