// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Multicallable} from "@solady/utils/Multicallable.sol";
import {ERC721Hook} from "@core-contracts/hook/ERC721Hook.sol";

import {NFTMetadataRenderer} from "../../lib/NFTMetadataRenderer.sol";
import {SharedMetadataStorage} from "../../storage/SharedMetadataStorage.sol";
import {ISharedMetadata} from "../../interface/ISharedMetadata.sol";

contract OpenEditionHookERC721 is ISharedMetadata, ERC721Hook, Multicallable {
    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    event BatchMetadataUpdate(address indexed token, uint256 _fromTokenId, uint256 _toTokenId);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when caller is not token core admin.
    error OpenEditionHookNotAuthorized();

    /*//////////////////////////////////////////////////////////////
                                INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function initialize(address _upgradeAdmin) public initializer {
        __ERC721Hook_init(_upgradeAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Returns all hooks implemented by the contract and all hook contract functions to register as
     *          callable via core contract fallback function.
     */
    function getHookInfo() external pure returns (HookInfo memory hookInfo) {
        hookInfo.hookFlags = ON_TOKEN_URI_FLAG();
        hookInfo.hookFallbackFunctions = new HookFallbackFunction[](1);
        hookInfo.hookFallbackFunctions[0] =
            HookFallbackFunction({functionSelector: this.setSharedMetadata.selector, callType: CallType.CALL});
    }

    /**
     *  @notice Returns the URI to fetch token metadata from.
     *  @dev Meant to be called by the core token contract.
     *  @param _id The token ID of the NFT.
     */
    function onTokenURI(uint256 _id) external view override returns (string memory) {
        return _getURIFromSharedMetadata(msg.sender, _id);
    }

    /*//////////////////////////////////////////////////////////////
                        Shared metadata logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Set shared metadata for NFTs
    function setSharedMetadata(SharedMetadataInfo calldata _metadata) external {
        address token = msg.sender;

        SharedMetadataStorage.data().sharedMetadata[token] = SharedMetadataInfo({
            name: _metadata.name,
            description: _metadata.description,
            imageURI: _metadata.imageURI,
            animationURI: _metadata.animationURI
        });

        emit BatchMetadataUpdate(token, 0, type(uint256).max);

        emit SharedMetadataUpdated(
            token, _metadata.name, _metadata.description, _metadata.imageURI, _metadata.animationURI
        );
    }

    /**
     *  @dev Token URI information getter
     *  @param tokenId Token ID to get URI for
     */
    function _getURIFromSharedMetadata(address _token, uint256 tokenId) internal view returns (string memory) {
        SharedMetadataInfo memory info = SharedMetadataStorage.data().sharedMetadata[_token];

        return NFTMetadataRenderer.createMetadataEdition({
            name: info.name,
            description: info.description,
            imageURI: info.imageURI,
            animationURI: info.animationURI,
            tokenOfEdition: tokenId
        });
    }
}
