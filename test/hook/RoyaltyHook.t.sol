// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CloneFactory} from "src/infra/CloneFactory.sol";
import {EIP1967Proxy} from "src/infra/EIP1967Proxy.sol";

import {ERC721Core, HookInstaller} from "src/core/token/ERC721Core.sol";
import {RoyaltyHook} from "src/hook/royalty/RoyaltyHook.sol";

contract RoyaltyHookTest is Test {
    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Participants
    address public platformAdmin = address(0x123);
    address public developer = address(0x456);
    address public endUser = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;

    // Target test contracts
    ERC721Core public erc721Core;
    RoyaltyHook public royaltyHook;

    uint256 public constant ROYALTY_INFO_FLAG = 2 ** 6;

    function setUp() public {
        // Platform deploys metadata hook.
        address royaltyHookImpl = address(new RoyaltyHook());

        bytes memory initData = abi.encodeWithSelector(
            RoyaltyHook.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address royaltyHookProxy = address(new EIP1967Proxy(royaltyHookImpl, initData));
        royaltyHook = RoyaltyHook(royaltyHookProxy);

        // Platform deploys ERC721 core implementation and clone factory.
        address erc721CoreImpl = address(new ERC721Core());
        CloneFactory factory = new CloneFactory();

        vm.startPrank(developer);

        ERC721Core.InitCall memory initCall;
        address[] memory preinstallHooks = new address[](1);
        preinstallHooks[0] = address(royaltyHook);

        bytes memory erc721InitData = abi.encodeWithSelector(
            ERC721Core.initialize.selector,
            initCall,
            preinstallHooks,
            developer, // core contract admin
            "Test ERC721",
            "TST",
            "ipfs://QmPVMvePSWfYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/0" // mock contract URI of actual length
        );
        erc721Core = ERC721Core(factory.deployProxyByImplementation(erc721CoreImpl, erc721InitData, bytes32("salt")));

        vm.stopPrank();

        // Set labels
        vm.deal(endUser, 100 ether);

        vm.label(platformAdmin, "Admin");
        vm.label(developer, "Developer");
        vm.label(endUser, "Claimer");

        vm.label(address(erc721Core), "ERC721Core");
        vm.label(address(royaltyHookImpl), "royaltyHook");
        vm.label(royaltyHookProxy, "ProxyRoyaltyHook");
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function test_defaultRoyalty_state() public {
        address recipient = address(0x121212);
        uint256 bps = 1000; // 10%

        vm.prank(developer);
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG, abi.encodeWithSelector(RoyaltyHook.setDefaultRoyaltyInfo.selector, recipient, bps)
        );

        (address _recipient, uint256 _bps) = royaltyHook.getDefaultRoyaltyInfo(address(erc721Core));
        assertEq(_recipient, recipient);
        assertEq(_bps, bps);

        uint256 price = 1 ether;

        vm.prank(address(erc721Core));
        (address receiver, uint256 royaltyAmount) = royaltyHook.royaltyInfo(0, price);

        assertEq(receiver, recipient);
        assertEq(royaltyAmount, (price * bps) / 10_000);
    }

    function test_defaultRoyalty_revert_exceedMaxBps() public {
        address recipient = address(0x121212);
        uint256 bps = 100_000; // 1000%

        vm.prank(developer);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyHook.RoyaltyHookExceedsMaxBps.selector));
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG, abi.encodeWithSelector(RoyaltyHook.setDefaultRoyaltyInfo.selector, recipient, bps)
        );
    }

    function test_defaultRoyalty_revert_notAdminOfToken() public {
        address recipient = address(0x121212);
        uint256 bps = 1000; // 10%

        vm.expectRevert(abi.encodeWithSelector(HookInstaller.HookInstallerUnauthorizedWrite.selector));
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG, abi.encodeWithSelector(RoyaltyHook.setDefaultRoyaltyInfo.selector, recipient, bps)
        );
    }

    function test_royaltyForToken_state() public {
        uint256 tokenId = 0;

        address recipient = address(0x121212);
        uint256 bps = 1000; // 10%

        vm.prank(developer);
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG, abi.encodeWithSelector(RoyaltyHook.setDefaultRoyaltyInfo.selector, recipient, bps)
        );

        (address _recipient, uint256 _bps) = royaltyHook.getDefaultRoyaltyInfo(address(erc721Core));
        assertEq(_recipient, recipient);
        assertEq(_bps, bps);

        uint256 price = 1 ether;

        vm.prank(address(erc721Core));
        (address receiver, uint256 royaltyAmount) = royaltyHook.royaltyInfo(tokenId, price);

        assertEq(receiver, recipient);
        assertEq(royaltyAmount, (price * bps) / 10_000);

        address overrideRecipient = address(0x13131313);
        uint256 overrideBps = 5000; // 50%

        vm.prank(developer);
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG,
            abi.encodeWithSelector(royaltyHook.setRoyaltyInfoForToken.selector, tokenId, overrideRecipient, overrideBps)
        );

        vm.prank(address(erc721Core));
        (receiver, royaltyAmount) = royaltyHook.royaltyInfo(tokenId, price);

        assertEq(receiver, overrideRecipient);
        assertEq(royaltyAmount, (price * overrideBps) / 10_000);
    }

    function test_royaltyForToken_revert_exceedMaxBps() public {
        uint256 tokenId = 0;

        address overrideRecipient = address(0x13131313);
        uint256 overrideBps = 100_000; // 1000%

        vm.prank(developer);
        vm.expectRevert(abi.encodeWithSelector(RoyaltyHook.RoyaltyHookExceedsMaxBps.selector));
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG,
            abi.encodeWithSelector(RoyaltyHook.setRoyaltyInfoForToken.selector, tokenId, overrideRecipient, overrideBps)
        );
    }

    function test_royaltyForToken_revert_notAdminOfToken() public {
        uint256 tokenId = 0;

        address overrideRecipient = address(0x13131313);
        uint256 overrideBps = 5000; // 50%

        vm.expectRevert(abi.encodeWithSelector(HookInstaller.HookInstallerUnauthorizedWrite.selector));
        erc721Core.hookFunctionWrite(
            ROYALTY_INFO_FLAG,
            abi.encodeWithSelector(RoyaltyHook.setRoyaltyInfoForToken.selector, tokenId, overrideRecipient, overrideBps)
        );
    }
}
