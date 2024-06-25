// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {ModularExtension} from "../../../ModularExtension.sol";
import {Role} from "../../../Role.sol";
import {LibString} from "@solady/utils/LibString.sol";

library DelayedRevealBatchMetadataStorage {
    /// @custom:storage-location erc7201:token.metadata.batch.delayed.reveal
    bytes32 public constant DELAYED_REVEAL_BATCH_METADATA_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("token.metadata.batch.delayed.reveal")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        // tokenId range end
        uint256[] tokenIdRangeEnd;
        // next tokenId as range start
        uint256 nextTokenIdRangeStart;
        // tokenId range end => baseURI of range
        mapping(uint256 => string) baseURIOfTokenIdRange;
        // tokenId range end => encrypted data for that range
        mapping(uint256 => bytes) encryptedData;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = DELAYED_REVEAL_BATCH_METADATA_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract DelayedRevealBatchMetadataERC721 is ModularExtension {
    using LibString for uint256;

    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     *   @notice MetadataBatch struct to store metadata for a range of tokenIds.
     *   @param startTokenIdInclusive The first tokenId in the range.
     *   @param endTokenIdNonInclusive The last tokenId in the range.
     *   @param baseURI The base URI for the range.
     */
    struct DelayedRevealMetadataBatch {
        uint256 startTokenIdInclusive;
        uint256 endTokenIdInclusive;
        string baseURI;
        bytes encryptedData;
    }

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when uploading metadata for zero tokens.
    error BatchMetadataZeroAmount();

    /// @dev Emitted when trying to fetch metadata for a token that has no metadata.
    error BatchMetadataNoMetadataForTokenId();

    /// @dev The contract doesn't have any url to be delayed revealed
    error DelayedRevealNothingToReveal();

    /// @dev The result of the returned an incorrect hash
    error DelayedRevealIncorrectDecryptionKey(bytes32 expected, bytes32 actual);

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when a new metadata batch is uploaded.
    event NewMetadataBatch(
        uint256 indexed startTokenIdInclusive, uint256 indexed endTokenIdNonInclusive, string baseURI
    );

    /// @dev ERC-4906 Metadata Update.
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);

    /// @dev Emitted when tokens are revealed.
    event TokenURIRevealed(uint256 indexed index, string revealedURI);

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and extension functions.
    function getExtensionConfig() external pure virtual override returns (ExtensionConfig memory config) {
        config.callbackFunctions = new CallbackFunction[](1);
        config.fallbackFunctions = new FallbackFunction[](3);

        config.callbackFunctions[0] = CallbackFunction(this.onTokenURI.selector);
        config.fallbackFunctions[0] =
            FallbackFunction({selector: this.uploadMetadata.selector, permissionBits: Role._MINTER_ROLE});
        config.fallbackFunctions[1] =
            FallbackFunction({selector: this.getAllMetadataBatches.selector, permissionBits: 0});
        config.fallbackFunctions[2] =
            FallbackFunction({selector: this.reveal.selector, permissionBits: Role._MINTER_ROLE});

        config.requiredInterfaces = new bytes4[](1);
        config.requiredInterfaces[0] = 0x80ac58cd; // ERC721.

        config.supportedInterfaces = new bytes4[](1);
        config.supportedInterfaces[0] = 0x49064906; // ERC4906.
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback function for ERC721Metadata.tokenURI
    function onTokenURI(uint256 _id) public view returns (string memory) {
        (string memory batchUri, bool isEncrypted) = _getBaseURI(_id);

        if (isEncrypted) {
            return string(abi.encodePacked(batchUri, "0"));
        } else {
            return string(abi.encodePacked(batchUri, _id.toString()));
        }
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all metadata batches for a token.
    function getAllMetadataBatches() external view returns (DelayedRevealMetadataBatch[] memory) {
        uint256[] memory rangeEnds = _delayedRevealBatchMetadataStorage().tokenIdRangeEnd;
        uint256 numOfBatches = rangeEnds.length;

        DelayedRevealMetadataBatch[] memory batches = new DelayedRevealMetadataBatch[](rangeEnds.length);

        uint256 rangeStart = 0;
        for (uint256 i = 0; i < numOfBatches; i += 1) {
            batches[i] = DelayedRevealMetadataBatch({
                startTokenIdInclusive: rangeStart,
                endTokenIdInclusive: rangeEnds[i] - 1,
                baseURI: _delayedRevealBatchMetadataStorage().baseURIOfTokenIdRange[rangeEnds[i]],
                encryptedData: _delayedRevealBatchMetadataStorage().encryptedData[rangeEnds[i]]
            });
            rangeStart = rangeEnds[i];
        }

        return batches;
    }

    /// @notice Uploads metadata for a range of tokenIds.
    function uploadMetadata(uint256 _amount, string calldata _baseURI, bytes memory _data) public virtual {
        if (_amount == 0) {
            revert BatchMetadataZeroAmount();
        }

        uint256 rangeStart = _delayedRevealBatchMetadataStorage().nextTokenIdRangeStart;
        uint256 rangeEndNonInclusive = rangeStart + _amount;

        if (_data.length > 0) {
            (bytes memory encryptedURI, bytes32 provenanceHash) = abi.decode(_data, (bytes, bytes32));
            if (encryptedURI.length != 0 && provenanceHash != "") {
                _delayedRevealBatchMetadataStorage().encryptedData[rangeEndNonInclusive] = _data;
            }
        }

        _delayedRevealBatchMetadataStorage().nextTokenIdRangeStart = rangeEndNonInclusive;
        _delayedRevealBatchMetadataStorage().tokenIdRangeEnd.push(rangeEndNonInclusive);
        _delayedRevealBatchMetadataStorage().baseURIOfTokenIdRange[rangeEndNonInclusive] = _baseURI;

        emit NewMetadataBatch(rangeStart, rangeEndNonInclusive, _baseURI);
        emit BatchMetadataUpdate(rangeStart, rangeEndNonInclusive - 1);
    }

    /// @notice reveals the URI for a range of 'delayed-reveal' tokens.
    function reveal(uint256 _index, bytes calldata _key) public returns (string memory revealedURI) {
        uint256 _rangeEndNonInclusive = _delayedRevealBatchMetadataStorage().tokenIdRangeEnd[_index];
        revealedURI = _getRevealURI(_rangeEndNonInclusive, _key);

        _delayedRevealBatchMetadataStorage().encryptedData[_rangeEndNonInclusive] = "";
        _delayedRevealBatchMetadataStorage().baseURIOfTokenIdRange[_rangeEndNonInclusive] = revealedURI;

        emit TokenURIRevealed(_index, revealedURI);

        uint256 rangeStart = _index == 0 ? 0 : _delayedRevealBatchMetadataStorage().tokenIdRangeEnd[_index - 1];
        emit BatchMetadataUpdate(rangeStart, _rangeEndNonInclusive - 1);
    }

    /*//////////////////////////////////////////////////////////////
                            Encode `uploadMetadata`
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns bytes encoded metadata, to be used in `uploadedMetadata` fallback function
    function encodeBytesUploadMetadata(bytes memory encryptedURI, bytes32 provenanceHash)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(encryptedURI, provenanceHash);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice         Encrypt/decrypt data on chain.
     *  @dev            Encrypt/decrypt given `data` with `key`. Uses inline assembly.
     *                  See: https://ethereum.stackexchange.com/questions/69825/decrypt-message-on-chain
     */
    function _encryptDecrypt(bytes memory data, bytes calldata key) internal pure returns (bytes memory result) {
        // Store data length on stack for later use
        uint256 length = data.length;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Set result to free memory pointer
            result := mload(0x40)
            // Increase free memory pointer by lenght + 32
            mstore(0x40, add(add(result, length), 32))
            // Set result length
            mstore(result, length)
        }

        // Iterate over the data stepping by 32 bytes
        for (uint256 i = 0; i < length; i += 32) {
            // Generate hash of the key and offset
            bytes32 hash = keccak256(abi.encodePacked(key, i));

            bytes32 chunk;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Read 32-bytes data chunk
                chunk := mload(add(data, add(i, 32)))
            }
            // XOR the chunk with hash
            chunk ^= hash;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                // Write 32-byte encrypted chunk
                mstore(add(result, add(i, 32)), chunk)
            }
        }
    }

    /// @dev Returns the baseURI for a token. The intended metadata URI for the token is baseURI + tokenId.
    function _getBaseURI(uint256 _tokenId) internal view returns (string memory, bool) {
        uint256[] memory rangeEnds = _delayedRevealBatchMetadataStorage().tokenIdRangeEnd;
        uint256 numOfBatches = rangeEnds.length;

        for (uint256 i = 0; i < numOfBatches; i += 1) {
            if (_tokenId < rangeEnds[i]) {
                bytes memory encryptedData = _delayedRevealBatchMetadataStorage().encryptedData[rangeEnds[i]];
                bool isEncrypted = encryptedData.length > 0;

                return (_delayedRevealBatchMetadataStorage().baseURIOfTokenIdRange[rangeEnds[i]], isEncrypted);
            }
        }
        revert BatchMetadataNoMetadataForTokenId();
    }

    /// @notice unencrypted URI for a range of 'delayed-reveal' tokens.
    function _getRevealURI(uint256 _rangeEndNonInclusive, bytes calldata _key)
        internal
        view
        returns (string memory revealedURI)
    {
        bytes memory data = _delayedRevealBatchMetadataStorage().encryptedData[_rangeEndNonInclusive];
        if (data.length == 0) {
            revert DelayedRevealNothingToReveal();
        }

        (bytes memory encryptedURI, bytes32 provenanceHash) = abi.decode(data, (bytes, bytes32));

        revealedURI = string(_encryptDecrypt(encryptedURI, _key));

        if (keccak256(abi.encodePacked(revealedURI, _key, block.chainid)) != provenanceHash) {
            revert DelayedRevealIncorrectDecryptionKey(
                provenanceHash, keccak256(abi.encodePacked(revealedURI, _key, block.chainid))
            );
        }
    }

    function _delayedRevealBatchMetadataStorage()
        internal
        pure
        returns (DelayedRevealBatchMetadataStorage.Data storage)
    {
        return DelayedRevealBatchMetadataStorage.data();
    }
}
