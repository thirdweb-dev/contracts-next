// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ModularExtension} from "../../../ModularExtension.sol";
import {IInstallationCallback} from "../../../interface/IInstallationCallback.sol";
import {Role} from "../../../Role.sol";

library RoyaltyStorage {
    /// @custom:storage-location erc7201:token.royalty
    bytes32 public constant ROYALTY_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("token.royalty")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        // default royalty info
        RoyaltyERC721.RoyaltyInfo defaultRoyaltyInfo;
        // tokenId => royalty info
        mapping(uint256 => RoyaltyERC721.RoyaltyInfo) royaltyInfoForToken;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = ROYALTY_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract RoyaltyERC721 is ModularExtension, IInstallationCallback {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     *   @notice RoyaltyInfo struct to store royalty information.
     *   @param recipient The address that will receive the royalty payment.
     *   @param bps The percentage of a secondary sale that will be paid as royalty.
     */
    struct RoyaltyInfo {
        address recipient;
        uint256 bps;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the default royalty info for a token is updated.
    event DefaultRoyaltyUpdate(address indexed recipient, uint256 bps);

    /// @notice Emitted when the royalty info for a specific NFT is updated.
    event TokenRoyaltyUpdate(uint256 indexed tokenId, address indexed recipient, uint256 bps);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when royalty BPS exceeds 10,000.
    error RoyaltyExceedsMaxBps();

    /*//////////////////////////////////////////////////////////////
                               EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and extension functions.
    function getExtensionConfig() external pure virtual override returns (ExtensionConfig memory config) {
        config.fallbackFunctions = new FallbackFunction[](5);

        config.fallbackFunctions[0] = FallbackFunction({selector: this.royaltyInfo.selector, permissionBits: 0});
        config.fallbackFunctions[1] =
            FallbackFunction({selector: this.getDefaultRoyaltyInfo.selector, permissionBits: 0});
        config.fallbackFunctions[2] =
            FallbackFunction({selector: this.getRoyaltyInfoForToken.selector, permissionBits: 0});
        config.fallbackFunctions[3] =
            FallbackFunction({selector: this.setDefaultRoyaltyInfo.selector, permissionBits: Role._MANAGER_ROLE});
        config.fallbackFunctions[4] =
            FallbackFunction({selector: this.setRoyaltyInfoForToken.selector, permissionBits: Role._MANAGER_ROLE});

        config.requiredInterfaces = new bytes4[](1);
        config.requiredInterfaces[0] = 0x80ac58cd; // ERC721.

        config.supportedInterfaces = new bytes4[](1);
        config.supportedInterfaces[0] = 0x2a55205a; // IERC2981.

        config.registerInstallationCallback = true;
    }

    /*//////////////////////////////////////////////////////////////
                    Encode install / uninstall data
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns bytes encoded install params, to be sent to `onInstall` function
    function encodeBytesOnInstall(address royaltyRecipient, uint256 royaltyBps) external pure returns (bytes memory) {
        return abi.encode(royaltyRecipient, royaltyBps);
    }

    /// @dev Returns bytes encoded uninstall params, to be sent to `onUninstall` function
    function encodeBytesOnUninstall() external pure returns (bytes memory) {
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Called by a Core into an Extension during the installation of the Extension.
    function onInstall(bytes calldata data) external {
        (address royaltyRecipient, uint256 royaltyBps) = abi.decode(data, (address, uint256));
        setDefaultRoyaltyInfo(royaltyRecipient, royaltyBps);
    }

    /// @dev Called by a Core into an Extension during the uninstallation of the Extension.
    function onUninstall(bytes calldata data) external {}

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the royalty recipient and amount for a given sale.
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice)
        external
        view
        virtual
        returns (address receiver, uint256 royaltyAmount)
    {
        (address overrideRecipient, uint16 overrideBps) = getRoyaltyInfoForToken(_tokenId);
        (address defaultRecipient, uint16 defaultBps) = getDefaultRoyaltyInfo();

        receiver = overrideRecipient == address(0) ? defaultRecipient : overrideRecipient;

        uint16 bps = overrideBps == 0 ? defaultBps : overrideBps;
        royaltyAmount = (_salePrice * bps) / 10_000;
    }

    /// @notice Returns the overriden royalty info for a given token.
    function getRoyaltyInfoForToken(uint256 _tokenId) public view returns (address, uint16) {
        RoyaltyStorage.Data storage data = RoyaltyStorage.data();
        RoyaltyInfo memory royaltyForToken = data.royaltyInfoForToken[_tokenId];

        return (royaltyForToken.recipient, uint16(royaltyForToken.bps));
    }

    /// @notice Returns the default royalty info for a given token.
    function getDefaultRoyaltyInfo() public view returns (address, uint16) {
        RoyaltyInfo memory defaultRoyaltyInfo = RoyaltyStorage.data().defaultRoyaltyInfo;
        return (defaultRoyaltyInfo.recipient, uint16(defaultRoyaltyInfo.bps));
    }

    /// @notice Sets the default royalty info for a given token.
    function setDefaultRoyaltyInfo(address _royaltyRecipient, uint256 _royaltyBps) public {
        if (_royaltyBps > 10_000) {
            revert RoyaltyExceedsMaxBps();
        }

        RoyaltyStorage.data().defaultRoyaltyInfo = RoyaltyInfo({recipient: _royaltyRecipient, bps: _royaltyBps});

        emit DefaultRoyaltyUpdate(_royaltyRecipient, _royaltyBps);
    }

    /// @notice Sets the royalty info for a specific NFT of a token collection.
    function setRoyaltyInfoForToken(uint256 _tokenId, address _recipient, uint256 _bps) external {
        if (_bps > 10_000) {
            revert RoyaltyExceedsMaxBps();
        }

        RoyaltyStorage.data().royaltyInfoForToken[_tokenId] = RoyaltyInfo({recipient: _recipient, bps: _bps});

        emit TokenRoyaltyUpdate(_tokenId, _recipient, _bps);
    }
}
