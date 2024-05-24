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
import {ERC20Core} from "src/core/token/ERC20Core.sol";
import {TransferableERC20} from "src/extension/token/transferable/TransferableERC20.sol";

contract TransferableExt is TransferableERC20 {}

contract Core is ERC20Core {
    constructor(
        address _erc1967Factory,
        string memory name,
        string memory symbol,
        string memory contractURI,
        address owner,
        address[] memory extensions,
        bytes[] memory extensionInstallData
    ) payable ERC20Core(_erc1967Factory, name, symbol, contractURI, owner, extensions, extensionInstallData) {}

    // disable mint and approve callbacks for these tests
    function _beforeMint(address to, uint256 amount, bytes calldata data) internal override {}
    function _beforeApprove(address from, address to, uint256 amount) internal override {}
}

contract TransferableERC20Test is Test {
    Core public core;

    TransferableExt public extensionImplementation;
    TransferableExt public installedExtension;

    address public owner = address(0x1);
    address public actorOne = address(0x2);
    address public actorTwo = address(0x3);
    address public actorThree = address(0x4);

    function setUp() public {
        // Deterministic, canonical ERC1967Factory contract
        vm.etch(ERC1967FactoryConstants.ADDRESS, ERC1967FactoryConstants.BYTECODE);

        address[] memory extensions;
        bytes[] memory extensionData;

        core = new Core(ERC1967FactoryConstants.ADDRESS, "test", "TEST", "", owner, extensions, extensionData);
        extensionImplementation = new TransferableExt();

        // install extension
        vm.prank(owner);
        core.installExtension(address(extensionImplementation), "");

        IModularCore.InstalledExtension[] memory installedExtensions = core.getInstalledExtensions();
        installedExtension = TransferableExt(installedExtensions[0].implementation);

        // mint tokens
        core.mint(actorOne, 10 ether, "");
        core.mint(actorTwo, 10 ether, "");
        core.mint(actorThree, 10 ether, "");
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: `setTransferable`
    //////////////////////////////////////////////////////////////*/

    function test_state_setTransferable() public {
        // transfers enabled globally
        vm.prank(owner);
        TransferableExt(address(core)).setTransferable(true);

        // transfer tokens
        vm.prank(actorOne);
        core.transfer(actorTwo, 2 ether);

        // read state from core
        assertEq(core.balanceOf(actorOne), 8 ether);
        assertEq(core.balanceOf(actorTwo), 12 ether);
        assertEq(TransferableExt(address(core)).isTransferEnabled(), true);

        // transfers disabled globally
        vm.prank(owner);
        TransferableExt(address(core)).setTransferable(false);

        assertEq(TransferableExt(address(core)).isTransferEnabled(), false);

        // should revert on transfer tokens
        vm.prank(actorTwo);
        vm.expectRevert(TransferableERC20.TransferDisabled.selector);
        core.transfer(actorOne, 1);
    }

    function test_revert_setTransferable() public {
        vm.expectRevert(0x82b42900); // `Unauthorized()`
        TransferableExt(address(core)).setTransferable(true);
    }

    /*///////////////////////////////////////////////////////////////
                    Unit tests: `setTransferableFor`
    //////////////////////////////////////////////////////////////*/

    function test_state_setTransferableFor_from() public {
        // transfers disabled globally
        vm.startPrank(owner);
        TransferableExt(address(core)).setTransferable(false);
        TransferableExt(address(core)).setTransferableFor(actorOne, true);
        vm.stopPrank();

        // transfer tokens
        vm.prank(actorOne);
        core.transfer(actorTwo, 2 ether);

        // read state from core
        assertEq(core.balanceOf(actorOne), 8 ether);
        assertEq(core.balanceOf(actorTwo), 12 ether);
        assertEq(TransferableExt(address(core)).isTransferEnabled(), false);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorOne), true);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorTwo), false);

        // should revert when transfer not enabled for
        vm.prank(actorTwo);
        vm.expectRevert(TransferableERC20.TransferDisabled.selector);
        core.transfer(actorThree, 1);
    }

    function test_state_setTransferableFor_to() public {
        // transfers disabled globally
        vm.startPrank(owner);
        TransferableExt(address(core)).setTransferable(false);
        TransferableExt(address(core)).setTransferableFor(actorTwo, true);
        vm.stopPrank();

        // transfer tokens
        vm.prank(actorOne);
        core.transfer(actorTwo, 2 ether);

        // read state from core
        assertEq(core.balanceOf(actorOne), 8 ether);
        assertEq(core.balanceOf(actorTwo), 12 ether);
        assertEq(TransferableExt(address(core)).isTransferEnabled(), false);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorOne), false);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorTwo), true);

        // revert when transfers not enabled for
        vm.prank(actorOne);
        vm.expectRevert(TransferableERC20.TransferDisabled.selector);
        core.transfer(actorThree, 1);
    }

    function test_state_setTransferableFor_operator() public {
        // transfers disabled globally
        vm.startPrank(owner);
        TransferableExt(address(core)).setTransferable(false);
        TransferableExt(address(core)).setTransferableFor(actorOne, true);
        vm.stopPrank();

        // approve tokens to operator actorOne
        vm.prank(actorTwo);
        core.approve(actorOne, type(uint256).max);

        // transfer tokens
        vm.prank(actorOne);
        core.transferFrom(actorTwo, actorThree, 2 ether);

        // read state from core
        assertEq(core.balanceOf(actorTwo), 8 ether);
        assertEq(core.balanceOf(actorThree), 12 ether);
        assertEq(TransferableExt(address(core)).isTransferEnabled(), false);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorOne), true);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorTwo), false);
        assertEq(TransferableExt(address(core)).isTransferEnabledFor(actorThree), false);

        // revert when transfers not enabled for
        vm.prank(actorTwo);
        vm.expectRevert(TransferableERC20.TransferDisabled.selector);
        core.transferFrom(actorTwo, actorThree, 0);
    }

    function test_revert_setTransferableFor() public {
        vm.expectRevert(0x82b42900); // `Unauthorized()`
        TransferableExt(address(core)).setTransferableFor(actorOne, true);
    }
}
