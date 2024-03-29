// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {CloneFactory} from "test/utils/CloneFactory.sol";
import {EIP1967Proxy} from "test/utils/EIP1967Proxy.sol";

import {LibString} from "@solady/utils/LibString.sol";

import {ERC721Core, HookInstaller} from "@core-contracts/core/token/ERC721Core.sol";
import {IHook} from "@core-contracts/interface/hook/IHook.sol";
import {OpenEditionHookERC721, ERC721Hook} from "src/token/metadata/OpenEditionHook.sol";
import {ISharedMetadata} from "src/interface/ISharedMetadata.sol";
import {NFTMetadataRenderer} from "src/lib/NFTMetadataRenderer.sol";

contract OpenEditionHookERC721Test is Test {
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    // Participants
    address public platformAdmin = address(0x123);
    address public developer = address(0x456);
    address public endUser = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;

    // Target test contracts
    ERC721Core public erc721Core;
    OpenEditionHookERC721 public metadataHook;

    // Test params
    uint256 public constant ON_TOKEN_URI_FLAG = 2 ** 5;
    ISharedMetadata.SharedMetadataInfo public sharedMetadata;

    function setUp() public {
        // Platform deploys metadata hook.
        address hookImpl = address(new OpenEditionHookERC721());

        bytes memory initData = abi.encodeWithSelector(
            metadataHook.initialize.selector,
            platformAdmin // upgradeAdmin
        );
        address hookProxy = address(new EIP1967Proxy(hookImpl, initData));
        metadataHook = OpenEditionHookERC721(hookProxy);

        // Platform deploys ERC721 core implementation and clone factory.
        CloneFactory factory = new CloneFactory();

        vm.startPrank(developer);

        ERC721Core.OnInitializeParams memory onInitializeCall;
        ERC721Core.InstallHookParams[] memory hooksToInstallOnInit = new ERC721Core.InstallHookParams[](1);

        hooksToInstallOnInit[0].hook = IHook(address(metadataHook));

        erc721Core = new ERC721Core(
            "Test ERC721",
            "TST",
            "ipfs://QmPVMvePSWfYXTa8haCbFavYx4GM4kBPzvdgBw7PTGUByp/0",
            developer, // core contract owner
            onInitializeCall,
            hooksToInstallOnInit
        );

        vm.stopPrank();

        // Set labels
        vm.deal(endUser, 100 ether);

        vm.label(platformAdmin, "Admin");
        vm.label(developer, "Developer");
        vm.label(endUser, "Claimer");

        vm.label(address(erc721Core), "ERC721Core");
        vm.label(address(hookImpl), "metadataHookImpl");
        vm.label(hookProxy, "ProxymetadataHook");

        sharedMetadata = ISharedMetadata.SharedMetadataInfo({
            name: "Test",
            description: "Test",
            imageURI: "https://test.com",
            animationURI: "https://test.com"
        });
    }

    function test_setSharedMetadata_state() public {
        uint256 tokenId = 454;

        assertEq(
            erc721Core.tokenURI(tokenId),
            NFTMetadataRenderer.createMetadataEdition({
                name: "",
                description: "",
                imageURI: "",
                animationURI: "",
                tokenOfEdition: tokenId
            })
        );

        vm.prank(developer);
        address(erc721Core).call(
            abi.encodeWithSelector(OpenEditionHookERC721.setSharedMetadata.selector, sharedMetadata)
        );

        assertEq(
            erc721Core.tokenURI(tokenId),
            NFTMetadataRenderer.createMetadataEdition({
                name: sharedMetadata.name,
                description: sharedMetadata.description,
                imageURI: sharedMetadata.imageURI,
                animationURI: sharedMetadata.animationURI,
                tokenOfEdition: tokenId
            })
        );

        // test for arbitrary tokenId
        assertEq(
            erc721Core.tokenURI(1337),
            NFTMetadataRenderer.createMetadataEdition({
                name: sharedMetadata.name,
                description: sharedMetadata.description,
                imageURI: sharedMetadata.imageURI,
                animationURI: sharedMetadata.animationURI,
                tokenOfEdition: 1337
            })
        );
    }

    function test_revert_setSharedMetadata_notAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(HookInstaller.HookInstallerUnauthorizedWrite.selector));
        address(erc721Core).call(
            abi.encodeWithSelector(OpenEditionHookERC721.setSharedMetadata.selector, sharedMetadata)
        );
    }
}
