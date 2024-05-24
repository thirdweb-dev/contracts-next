// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "lib/forge-std/src/console.sol";

import {Test} from "forge-std/Test.sol";
import {ERC1967Factory} from "@solady/utils/ERC1967Factory.sol";
import {ERC1967FactoryConstants} from "@solady/utils/ERC1967FactoryConstants.sol";

// Target contract
import {IExtensionConfig} from "src/interface/IExtensionConfig.sol";
import {IModularCore} from "src/interface/IModularCore.sol";
import {ModularExtension} from "src/ModularExtension.sol";
import {ModularCoreUpgradeable} from "src/ModularCoreUpgradeable.sol";
import {ERC1155Core} from "src/core/token/ERC1155Core.sol";
import {RoyaltyERC1155} from "src/extension/token/royalty/RoyaltyERC1155.sol";

contract RoyaltyExt is RoyaltyERC1155 {}

contract RoyaltyERC1155Test is Test {
    ERC1155Core public core;

    RoyaltyExt public extensionImplementation;
    RoyaltyExt public installedExtension;

    address public owner = address(0x1);
    address public permissionedActor = address(0x2);
    address public unpermissionedActor = address(0x3);

    function setUp() public {
        // Deterministic, canonical ERC1967Factory contract
        vm.etch(ERC1967FactoryConstants.ADDRESS, ERC1967FactoryConstants.BYTECODE);

        address[] memory extensions;
        bytes[] memory extensionData;

        core = new ERC1155Core(ERC1967FactoryConstants.ADDRESS, "test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new RoyaltyExt();

        // install extension
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), "");

        IModularCore.InstalledExtension[] memory installedExtensions = core.getInstalledExtensions();
        installedExtension = RoyaltyExt(installedExtensions[0].implementation);
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: `setDefaultRoyaltyInfo`
    //////////////////////////////////////////////////////////////*/

    function test_state_setDefaultRoyaltyInfo() public {
        address royaltyRecipient = address(0x123);
        uint256 royaltyBps = 100;

        vm.prank(owner);
        RoyaltyExt(address(core)).setDefaultRoyaltyInfo(royaltyRecipient, royaltyBps);

        address receiver;
        uint256 royaltyAmount;
        uint16 bps;

        // read state from extension
        (receiver, bps) = RoyaltyExt(address(core)).getDefaultRoyaltyInfo(address(core));
        assertEq(receiver, royaltyRecipient);
        assertEq(bps, royaltyBps);
        (receiver, bps) = RoyaltyExt(address(core)).getRoyaltyInfoForToken(address(core), 1);
        assertEq(receiver, address(0));
        assertEq(bps, 0);

        // read state from core
        uint256 salePrice = 1000;
        uint256 tokenId = 1;
        (receiver, royaltyAmount) = RoyaltyExt(address(core)).royaltyInfo(tokenId, salePrice);
        assertEq(receiver, royaltyRecipient);
        assertEq(royaltyAmount, (salePrice * royaltyBps) / 10_000);
    }

    function test_revert_setDefaultRoyaltyInfo() public {
        vm.expectRevert(0x82b42900); // `Unauthorized()`
        RoyaltyExt(address(core)).setDefaultRoyaltyInfo(address(0x123), 100);
    }

    function test_state_setRoyaltyInfoForToken() public {
        address defaultRoyaltyRecipient = address(0x123);
        uint256 defaultRoyaltyBps = 100;

        address customRoyaltyRecipient = address(0x345);
        uint256 customRoyaltyBps = 200;

        vm.startPrank(owner);
        RoyaltyExt(address(core)).setDefaultRoyaltyInfo(defaultRoyaltyRecipient, defaultRoyaltyBps);
        RoyaltyExt(address(core)).setRoyaltyInfoForToken(10, customRoyaltyRecipient, customRoyaltyBps);
        vm.stopPrank();

        address receiver;
        uint256 royaltyAmount;
        uint16 bps;

        // read state from extension
        (receiver, bps) = RoyaltyExt(address(core)).getDefaultRoyaltyInfo(address(core));
        assertEq(receiver, defaultRoyaltyRecipient);
        assertEq(bps, defaultRoyaltyBps);
        (receiver, bps) = RoyaltyExt(address(core)).getRoyaltyInfoForToken(address(core), 1);
        assertEq(receiver, address(0));
        assertEq(bps, 0);
        (receiver, bps) = RoyaltyExt(address(core)).getRoyaltyInfoForToken(address(core), 10);
        assertEq(receiver, customRoyaltyRecipient);
        assertEq(bps, customRoyaltyBps);

        // read state from core
        uint256 salePrice = 1000;
        uint256 tokenId = 1;

        (receiver, royaltyAmount) = RoyaltyExt(address(core)).royaltyInfo(tokenId, salePrice); // default royalty
        assertEq(receiver, defaultRoyaltyRecipient);
        assertEq(royaltyAmount, (salePrice * defaultRoyaltyBps) / 10_000);

        tokenId = 10;
        (receiver, royaltyAmount) = RoyaltyExt(address(core)).royaltyInfo(tokenId, salePrice); // custom royalty
        assertEq(receiver, customRoyaltyRecipient);
        assertEq(royaltyAmount, (salePrice * customRoyaltyBps) / 10_000);
    }

    function test_revert_setRoyaltyInfoForToken() public {
        vm.expectRevert(0x82b42900); // `Unauthorized()`
        RoyaltyExt(address(core)).setRoyaltyInfoForToken(10, address(0x123), 100);
    }
}
