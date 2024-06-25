// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import {ModularExtension} from "../../../ModularExtension.sol";
import {IInstallationCallback} from "../../../interface/IInstallationCallback.sol";
import {Role} from "../../../Role.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {ECDSA} from "@solady/utils/ECDSA.sol";
import {EIP712} from "@solady/utils/EIP712.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {BeforeMintCallbackERC1155} from "../../../callback/BeforeMintCallbackERC1155.sol";
import {OnTokenURICallback} from "../../../callback/OnTokenURICallback.sol";

library MintableStorage {
    /// @custom:storage-location erc7201:token.minting.mintable
    bytes32 public constant MINTABLE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("token.minting.mintable.erc1155")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        // UID => whether it has been used
        mapping(bytes32 => bool) uidUsed;
        // sale config
        MintableERC1155.SaleConfig saleConfig;
        // tokenId range end
        uint256[] tokenIdRangeEnd;
        // tokenId range end => baseURI of range
        mapping(uint256 => string) tokenURI;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = MINTABLE_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract MintableERC1155 is
    ModularExtension,
    EIP712,
    BeforeMintCallbackERC1155,
    OnTokenURICallback,
    IInstallationCallback
{
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice The request struct signed by an authorized party to mint tokens.
     *
     *  @param tokenId The ID of the token being minted.
     *  @param startTimestamp The timestamp at which the minting request is valid.
     *  @param endTimestamp The timestamp at which the minting request expires.
     *  @param recipient The address that will receive the minted tokens.
     *  @param quantity The quantity of tokens to mint.
     *  @param currency The address of the currency used to pay for the minted tokens.
     *  @param pricePerUnit The price per unit of the minted tokens.
     *  @param metadataURI The URI of the metadata for the minted token.
     *  @param uid A unique identifier for the minting request.
     */
    struct MintRequestERC1155 {
        uint256 tokenId;
        uint48 startTimestamp;
        uint48 endTimestamp;
        address recipient;
        uint256 quantity;
        address currency;
        uint256 pricePerUnit;
        string metadataURI;
        bytes32 uid;
    }

    /**
     *  @notice The parameters sent to the `beforeMintERC20` callback function.
     *
     *  @param request The minting request.
     *  @param signature The signature produced from signing the minting request.
     */
    struct MintParamsERC1155 {
        MintRequestERC1155 request;
        bytes signature;
        string metadataURI;
    }

    /**
     *  @notice The configuration of a token's sale value distribution.
     *
     *  @param primarySaleRecipient The address that receives the primary sale value.
     */
    struct SaleConfig {
        address primarySaleRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when an incorrect amount of native token is sent.
    error MintableIncorrectNativeTokenSent();

    /// @dev Emitted when the minting request has expired.
    error MintableRequestOutOfTimeWindow();

    /// @dev Emitted when the minting request UID has been reused.
    error MintableRequestUidReused();

    /// @dev Emitted when the minting request does not match the expected values.
    error MintableRequestMismatch();

    /// @dev Emitted when the minting request signature is unauthorized.
    error MintableRequestUnauthorized();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when a token's metadata URI is updated.
    event MintableTokenURIUpdated(uint256 tokenId, string tokenURI);

    /// @notice Emitted when the metadata URI for a token is updated.
    event MetadataUpdate(uint256 id);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant TYPEHASH_SIGNATURE_MINT_ERC1155 = keccak256(
        "MintRequestERC1155(uint256 tokenId,uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,string metadataURI,bytes32 uid)"
    );

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and fallback functions.
    function getExtensionConfig() external pure override returns (ExtensionConfig memory config) {
        config.callbackFunctions = new CallbackFunction[](2);
        config.fallbackFunctions = new FallbackFunction[](4);

        config.callbackFunctions[0] = CallbackFunction(this.beforeMintERC1155.selector);
        config.callbackFunctions[1] = CallbackFunction(this.onTokenURI.selector);

        config.fallbackFunctions[0] = FallbackFunction({selector: this.getSaleConfig.selector, permissionBits: 0});
        config.fallbackFunctions[1] =
            FallbackFunction({selector: this.setSaleConfig.selector, permissionBits: Role._MANAGER_ROLE});
        config.fallbackFunctions[2] =
            FallbackFunction({selector: this.setTokenURI.selector, permissionBits: Role._MINTER_ROLE});
        config.fallbackFunctions[3] = FallbackFunction({selector: this.eip712Domain.selector, permissionBits: 0});

        config.requiredInterfaces = new bytes4[](1);
        config.requiredInterfaces[0] = 0xd9b67a26; // ERC1155

        config.registerInstallationCallback = true;

        config.supportedInterfaces = new bytes4[](1);
        config.supportedInterfaces[0] = 0x49064906; // ERC4906.
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback function for the ERC721Core.tokenURI function.
    function onTokenURI(uint256 _tokenId) external view virtual override returns (string memory) {
        return _mintableStorage().tokenURI[_tokenId];
    }

    /// @notice Callback function for the ERC1155Core.mint function.
    function beforeMintERC1155(address _to, uint256 _id, uint256 _quantity, bytes memory _data)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        MintParamsERC1155 memory _params = abi.decode(_data, (MintParamsERC1155));

        // If the signature is empty, the caller must have the MINTER_ROLE.
        if (_params.signature.length == 0) {
            if (!OwnableRoles(address(this)).hasAllRoles(msg.sender, Role._MINTER_ROLE)) {
                revert MintableRequestUnauthorized();
            }

            if (bytes(_params.metadataURI).length > 0) {
                setTokenURI(_params.request.tokenId, _params.metadataURI);
            }

            // Else read and verify the payload and signature.
        } else {
            _mintWithSignatureERC1155(_to, _quantity, _id, _params.request, _params.signature);

            if (bytes(_params.request.metadataURI).length > 0) {
                setTokenURI(_params.request.tokenId, _params.request.metadataURI);
            }

            _distributeMintPrice(
                msg.sender, _params.request.currency, _params.request.quantity * _params.request.pricePerUnit
            );
        }
    }

    /// @dev Called by a Core into an Extension during the installation of the Extension.
    function onInstall(bytes calldata data) external {
        address primarySaleRecipient = abi.decode(data, (address));
        _mintableStorage().saleConfig = SaleConfig(primarySaleRecipient);
    }

    /// @dev Called by a Core into an Extension during the uninstallation of the Extension.
    function onUninstall(bytes calldata data) external {}

    /*//////////////////////////////////////////////////////////////
                    Encode install / uninstall data
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns bytes encoded install params, to be sent to `onInstall` function
    function encodeBytesOnInstall(address primarySaleRecipient) external pure returns (bytes memory) {
        return abi.encode(primarySaleRecipient);
    }

    /// @dev Returns bytes encoded uninstall params, to be sent to `onUninstall` function
    function encodeBytesOnUninstall() external pure returns (bytes memory) {
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                        Encode mint params
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns bytes encoded mint params, to be used in `beforeMint` fallback function
    function encodeBytesBeforeMintERC1155(MintParamsERC1155 memory params) external pure returns (bytes memory) {
        return abi.encode(params);
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the sale configuration for a token.
    function getSaleConfig() external view returns (address primarySaleRecipient) {
        SaleConfig memory saleConfig = _mintableStorage().saleConfig;
        return (saleConfig.primarySaleRecipient);
    }

    /// @notice Sets the sale configuration for a token.
    function setSaleConfig(address _primarySaleRecipient) external {
        _mintableStorage().saleConfig = SaleConfig(_primarySaleRecipient);
    }

    /// @notice Sets the token URI for a token.
    function setTokenURI(uint256 _tokenId, string memory _tokenURI) public {
        _mintableStorage().tokenURI[_tokenId] = _tokenURI;
        emit MintableTokenURIUpdated(_tokenId, _tokenURI);
        emit MetadataUpdate(_tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints tokens on verifying a signature from an authorized party.
    function _mintWithSignatureERC1155(
        address _expectedRecipient,
        uint256 _expectedAmount,
        uint256 _expectedTokenId,
        MintRequestERC1155 memory _req,
        bytes memory _signature
    ) internal {
        if (
            _req.recipient != _expectedRecipient || _req.quantity != _expectedAmount || _req.tokenId != _expectedTokenId
        ) {
            revert MintableRequestMismatch();
        }

        if (block.timestamp < _req.startTimestamp || _req.endTimestamp <= block.timestamp) {
            revert MintableRequestOutOfTimeWindow();
        }

        if (_mintableStorage().uidUsed[_req.uid]) {
            revert MintableRequestUidReused();
        }

        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    TYPEHASH_SIGNATURE_MINT_ERC1155,
                    _req.tokenId,
                    _req.startTimestamp,
                    _req.endTimestamp,
                    _req.recipient,
                    _req.quantity,
                    _req.currency,
                    _req.pricePerUnit,
                    keccak256(bytes(_req.metadataURI)),
                    _req.uid
                )
            )
        ).recover(_signature);

        if (!OwnableRoles(address(this)).hasAllRoles(signer, Role._MINTER_ROLE)) {
            revert MintableRequestUnauthorized();
        }

        _mintableStorage().uidUsed[_req.uid] = true;
    }

    /// @dev Distributes the minting price to the primary sale recipient and platform fee recipient.
    function _distributeMintPrice(address _owner, address _currency, uint256 _price) internal {
        if (_price == 0) {
            if (msg.value > 0) {
                revert MintableIncorrectNativeTokenSent();
            }
            return;
        }

        SaleConfig memory saleConfig = _mintableStorage().saleConfig;

        if (_currency == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != _price) {
                revert MintableIncorrectNativeTokenSent();
            }
            SafeTransferLib.safeTransferETH(saleConfig.primarySaleRecipient, _price);
        } else {
            if (msg.value > 0) {
                revert MintableIncorrectNativeTokenSent();
            }
            SafeTransferLib.safeTransferFrom(_currency, _owner, saleConfig.primarySaleRecipient, _price);
        }
    }
    /// @dev Returns the domain name and version for EIP712.

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "MintableERC1155";
        version = "1";
    }

    function _mintableStorage() internal pure returns (MintableStorage.Data storage) {
        return MintableStorage.data();
    }
}
