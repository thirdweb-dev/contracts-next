// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import {ModularExtension} from "../../../ModularExtension.sol";
import {IInstallationCallback} from "../../../interface/IInstallationCallback.sol";
import {Role} from "../../../Role.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {ECDSA} from "@solady/utils/ECDSA.sol";
import {EIP712} from "@solady/utils/EIP712.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {BeforeMintCallbackERC721} from "../../../callback/BeforeMintCallbackERC721.sol";
import {OnTokenURICallback} from "../../../callback/OnTokenURICallback.sol";

library MintableStorage {
    /// @custom:storage-location erc7201:token.minting.mintable
    bytes32 public constant MINTABLE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("token.minting.mintable.erc721")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        // UID => whether it has been used
        mapping(bytes32 => bool) uidUsed;
        // sale config
        MintableERC721.SaleConfig saleConfig;
        // tokenId range end
        uint256[] tokenIdRangeEnd;
        // tokenId range end => baseURI of range
        mapping(uint256 => string) baseURIOfTokenIdRange;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = MINTABLE_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract MintableERC721 is
    ModularExtension,
    EIP712,
    BeforeMintCallbackERC721,
    OnTokenURICallback,
    IInstallationCallback
{
    using ECDSA for bytes32;
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice The request struct signed by an authorized party to mint tokens.
     *
     *  @param startTimestamp The timestamp at which the minting request is valid.
     *  @param endTimestamp The timestamp at which the minting request expires.
     *  @param recipient The address that will receive the minted tokens.
     *  @param quantity The quantity of tokens to mint.
     *  @param currency The address of the currency used to pay for the minted tokens.
     *  @param pricePerUnit The price per unit of the minted tokens.
     *  @param baseURI The base URI for the range of minted token IDs.
     *  @param uid A unique identifier for the minting request.
     */
    struct MintRequestERC721 {
        uint48 startTimestamp;
        uint48 endTimestamp;
        address recipient;
        uint256 quantity;
        address currency;
        uint256 pricePerUnit;
        string baseURI;
        bytes32 uid;
    }

    /**
     *  @notice The parameters sent to the `beforeMintERC20` callback function.
     *
     *  @param request The minting request.
     *  @param signature The signature produced from signing the minting request.
     */
    struct MintParamsERC721 {
        MintRequestERC721 request;
        bytes signature;
        string baseURI;
    }

    /**
     *  @notice The configuration of a token's sale value distribution.
     *
     *  @param primarySaleRecipient The address that receives the primary sale value.
     */
    struct SaleConfig {
        address primarySaleRecipient;
    }

    /**
     *   @notice MetadataBatch struct to store metadata for a range of tokenIds.
     *   @param startTokenIdInclusive The first tokenId in the range.
     *   @param endTokenIdNonInclusive The last tokenId in the range.
     *   @param baseURI The base URI for the range.
     */
    struct MetadataBatch {
        uint256 startTokenIdInclusive;
        uint256 endTokenIdInclusive;
        string baseURI;
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

    /// @dev Emitted when the minting request token is invalid.
    error MintableRequestInvalidToken();

    /// @dev Emitted when the minting request does not match the expected values.
    error MintableRequestMismatch();

    /// @dev Emitted when the minting request signature is unauthorized.
    error MintableRequestUnauthorized();

    /// @dev Emitted when trying to fetch metadata for a token that has no metadata.
    error MintableNoMetadataForTokenId();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when a new metadata batch is uploaded.
    event NewMetadataBatch(
        uint256 indexed startTokenIdInclusive, uint256 indexed endTokenIdNonInclusive, string baseURI
    );

    /// @dev ERC-4906 Metadata Update.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant TYPEHASH_MINTABLE_ERC721 = keccak256(
        "MintRequestERC721(uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,string baseURI,bytes32 uid)"
    );

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and fallback functions.
    function getExtensionConfig() external pure override returns (ExtensionConfig memory config) {
        config.callbackFunctions = new CallbackFunction[](2);
        config.fallbackFunctions = new FallbackFunction[](4);

        config.callbackFunctions[0] = CallbackFunction(this.beforeMintERC721.selector);
        config.callbackFunctions[1] = CallbackFunction(this.onTokenURI.selector);

        config.fallbackFunctions[0] = FallbackFunction({selector: this.getSaleConfig.selector, permissionBits: 0});
        config.fallbackFunctions[1] =
            FallbackFunction({selector: this.setSaleConfig.selector, permissionBits: Role._MANAGER_ROLE});
        config.fallbackFunctions[2] = FallbackFunction({selector: this.eip712Domain.selector, permissionBits: 0});
        config.fallbackFunctions[3] =
            FallbackFunction({selector: this.getAllMetadataBatches.selector, permissionBits: 0});

        config.requiredInterfaces = new bytes4[](1);
        config.requiredInterfaces[0] = 0x80ac58cd; // ERC721.

        config.registerInstallationCallback = true;

        config.supportedInterfaces = new bytes4[](1);
        config.supportedInterfaces[0] = 0x49064906; // ERC4906.
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback function for ERC721Metadata.tokenURI
    function onTokenURI(uint256 _id) public view override returns (string memory) {
        string memory batchUri = _getBaseURI(_id);
        return string(abi.encodePacked(batchUri, _id.toString()));
    }

    /// @notice Callback function for the ERC721Core.mint function.
    function beforeMintERC721(address _to, uint256 _startTokenId, uint256 _quantity, bytes memory _data)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        MintParamsERC721 memory _params = abi.decode(_data, (MintParamsERC721));

        // If the signature is empty, the caller must have the MINTER_ROLE.
        if (_params.signature.length == 0) {
            if (!OwnableRoles(address(this)).hasAllRoles(msg.sender, Role._MINTER_ROLE)) {
                revert MintableRequestUnauthorized();
            }

            _setBaseURI(_startTokenId, _quantity, _params.baseURI);

            // Else read and verify the payload and signature.
        } else {
            _mintWithSignatureERC721(_to, _quantity, _startTokenId, _params.request, _params.signature);
            _setBaseURI(_startTokenId, _quantity, _params.request.baseURI);
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
    function encodeBytesBeforeMintERC721(MintParamsERC721 memory params) external pure returns (bytes memory) {
        return abi.encode(params);
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all metadata batches for a token.
    function getAllMetadataBatches() external view returns (MetadataBatch[] memory) {
        uint256[] memory rangeEnds = _mintableStorage().tokenIdRangeEnd;
        uint256 numOfBatches = rangeEnds.length;

        MetadataBatch[] memory batches = new MetadataBatch[](rangeEnds.length);

        uint256 rangeStart = 0;
        for (uint256 i = 0; i < numOfBatches; i += 1) {
            batches[i] = MetadataBatch({
                startTokenIdInclusive: rangeStart,
                endTokenIdInclusive: rangeEnds[i] - 1,
                baseURI: _mintableStorage().baseURIOfTokenIdRange[rangeEnds[i]]
            });
            rangeStart = rangeEnds[i];
        }

        return batches;
    }

    /// @notice Returns the sale configuration for a token.
    function getSaleConfig() external view returns (address primarySaleRecipient) {
        SaleConfig memory saleConfig = _mintableStorage().saleConfig;
        return (saleConfig.primarySaleRecipient);
    }

    /// @notice Sets the sale configuration for a token.
    function setSaleConfig(address _primarySaleRecipient) external {
        _mintableStorage().saleConfig = SaleConfig(_primarySaleRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Sets the metadata for a range of tokenIds.
    function _setBaseURI(uint256 _startTokenId, uint256 _amount, string memory _baseURI) internal {
        uint256 rangeStart = _startTokenId;
        uint256 rangeEndNonInclusive = rangeStart + _amount;

        _mintableStorage().tokenIdRangeEnd.push(rangeEndNonInclusive);
        _mintableStorage().baseURIOfTokenIdRange[rangeEndNonInclusive] = _baseURI;

        emit NewMetadataBatch(rangeStart, rangeEndNonInclusive, _baseURI);
        emit BatchMetadataUpdate(rangeStart, rangeEndNonInclusive - 1);
    }

    /// @dev Returns the baseURI for a token. The intended metadata URI for the token is baseURI + tokenId.
    function _getBaseURI(uint256 _tokenId) internal view returns (string memory) {
        uint256[] memory rangeEnds = _mintableStorage().tokenIdRangeEnd;
        uint256 numOfBatches = rangeEnds.length;

        for (uint256 i = 0; i < numOfBatches; i += 1) {
            if (_tokenId < rangeEnds[i]) {
                return _mintableStorage().baseURIOfTokenIdRange[rangeEnds[i]];
            }
        }
        revert MintableNoMetadataForTokenId();
    }

    /// @dev Mints tokens on verifying a signature from an authorized party.
    function _mintWithSignatureERC721(
        address _expectedRecipient,
        uint256 _expectedAmount,
        uint256 _startTokenId,
        MintRequestERC721 memory _req,
        bytes memory _signature
    ) internal {
        if (_req.recipient != _expectedRecipient || _req.quantity != _expectedAmount) {
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
                    TYPEHASH_MINTABLE_ERC721,
                    _req.startTimestamp,
                    _req.endTimestamp,
                    _req.recipient,
                    _req.quantity,
                    _req.currency,
                    _req.pricePerUnit,
                    keccak256(bytes(_req.baseURI)),
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
        name = "MintableERC721";
        version = "1";
    }

    function _mintableStorage() internal pure returns (MintableStorage.Data storage) {
        return MintableStorage.data();
    }
}
