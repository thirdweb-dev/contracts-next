// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import {ModularExtension} from "../../../ModularExtension.sol";
import {IInstallationCallback} from "../../../interface/IInstallationCallback.sol";
import {Role} from "../../../Role.sol";
import {OwnableRoles} from "@solady/auth/OwnableRoles.sol";
import {ECDSA} from "@solady/utils/ECDSA.sol";
import {EIP712} from "@solady/utils/EIP712.sol";
import {MerkleProofLib} from "@solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

import {BeforeMintCallbackERC721} from "../../../callback/BeforeMintCallbackERC721.sol";

library ClaimableStorage {
    /// @custom:storage-location erc7201:token.minting.claimable.erc721
    bytes32 public constant CLAIMABLE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("token.minting.claimable.erc721")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        // sale config: primary sale recipient, and platform fee recipient + BPS.
        ClaimableERC721.SaleConfig saleConfig;
        // claim condition
        ClaimableERC721.ClaimCondition claimCondition;
        // UID => whether it has been used
        mapping(bytes32 => bool) uidUsed;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = CLAIMABLE_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract ClaimableERC721 is ModularExtension, EIP712, BeforeMintCallbackERC721, IInstallationCallback {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                            STRUCTS & ENUMS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Details for distributing the proceeds of a mint.
     *  @param primarySaleRecipient The address to which the total proceeds minus fees are sent.
     */
    struct SaleConfig {
        address primarySaleRecipient;
    }

    /**
     *  @notice Conditions under which tokens can be minted.
     *  @param availableSupply The total number of tokens that can be minted.
     *  @param allowlistMerkleRoot The allowlist of addresses who can mint tokens.
     *  @param pricePerUnit The price per token.
     *  @param currency The currency in which the price is denominated.
     *  @param startTimestamp The timestamp at which the minting window opens.
     *  @param endTimestamp The timestamp after which the minting window closes.
     *  @param auxData Use to store arbitrary data. i.e: merkle snapshot url
     */
    struct ClaimCondition {
        uint256 availableSupply;
        bytes32 allowlistMerkleRoot;
        uint256 pricePerUnit;
        address currency;
        uint48 startTimestamp;
        uint48 endTimestamp;
        string auxData;
    }

    /**
     *  @notice The request struct signed by an authorized party to mint tokens.
     *
     *  @param startTimestamp The timestamp at which the minting request is valid.
     *  @param endTimestamp The timestamp at which the minting request expires.
     *  @param recipient The address that will receive the minted tokens.
     *  @param quantity The quantity of tokens to mint.
     *  @param currency The address of the currency used to pay for the minted tokens.
     *  @param pricePerUnit The price per unit of the minted tokens.
     *  @param uid A unique identifier for the minting request.
     */
    struct ClaimRequestERC721 {
        uint48 startTimestamp;
        uint48 endTimestamp;
        address recipient;
        uint256 quantity;
        address currency;
        uint256 pricePerUnit;
        bytes32 uid;
    }

    /**
     *  @notice The parameters sent to the `beforeMintERC20` callback function.
     *
     *  @param request The minting request.
     *  @param signature The signature produced from signing the minting request.
     */
    struct ClaimParamsERC721 {
        ClaimRequestERC721 request;
        bytes signature;
        address currency;
        uint256 pricePerUnit;
        bytes32[] recipientAllowlistProof;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Emitted when incorrect amount of native token is sent.
    error ClaimableIncorrectNativeTokenSent();

    /// @dev Emitted when the minting request does not match the expected values.
    error ClaimableRequestMismatch();

    /// @dev Emitted when the minting request has expired.
    error ClaimableRequestOutOfTimeWindow();

    /// @dev Emitted when the minting request UID has been reused.
    error ClaimableRequestUidReused();

    /// @dev Emitted when the minting request signature is unauthorized.
    error ClaimableRequestUnauthorizedSignature();

    /// @dev Emitted when the mint is attempted outside the minting window.
    error ClaimableOutOfTimeWindow();

    /// @dev Emitted when the mint is out of supply.
    error ClaimableOutOfSupply();

    /// @dev Emitted when the mint is priced at an unexpected price or currency.
    error ClaimableIncorrectPriceOrCurrency();

    /// @dev Emitted when the minter is not in the allowlist.
    error ClaimableNotInAllowlist();

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant TYPEHASH_CLAIMABLE_ERC721 = keccak256(
        "ClaimRequestERC721(uint48 startTimestamp,uint48 endTimestamp,address recipient,uint256 quantity,address currency,uint256 pricePerUnit,bytes32 uid)"
    );

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and fallback functions.
    function getExtensionConfig() external pure override returns (ExtensionConfig memory config) {
        config.callbackFunctions = new CallbackFunction[](1);
        config.fallbackFunctions = new FallbackFunction[](5);

        config.callbackFunctions[0] = CallbackFunction(this.beforeMintERC721.selector);

        config.fallbackFunctions[0] = FallbackFunction({selector: this.getSaleConfig.selector, permissionBits: 0});
        config.fallbackFunctions[1] =
            FallbackFunction({selector: this.setSaleConfig.selector, permissionBits: Role._MANAGER_ROLE});
        config.fallbackFunctions[2] = FallbackFunction({selector: this.getClaimCondition.selector, permissionBits: 0});
        config.fallbackFunctions[3] =
            FallbackFunction({selector: this.setClaimCondition.selector, permissionBits: Role._MINTER_ROLE});
        config.fallbackFunctions[4] = FallbackFunction({selector: this.eip712Domain.selector, permissionBits: 0});

        config.requiredInterfaces = new bytes4[](1);
        config.requiredInterfaces[0] = 0x80ac58cd; // ERC721.

        config.registerInstallationCallback = true;
    }

    /*//////////////////////////////////////////////////////////////
                            CALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback function for the ERC721Core.mint function.
    function beforeMintERC721(address _to, uint256 _startTokenId, uint256 _quantity, bytes memory _data)
        external
        payable
        virtual
        override
        returns (bytes memory)
    {
        ClaimParamsERC721 memory _params = abi.decode(_data, (ClaimParamsERC721));

        address currency;
        uint256 pricePerUnit;

        if (_params.signature.length == 0) {
            _validateClaimCondition(
                _to, _quantity, _params.currency, _params.pricePerUnit, _params.recipientAllowlistProof
            );
            currency = _params.currency;
            pricePerUnit = _params.pricePerUnit;
        } else {
            _validateClaimRequest(_to, _quantity, _params.request, _params.signature);
            currency = _params.request.currency;
            pricePerUnit = _params.request.pricePerUnit;
        }

        _distributeMintPrice(msg.sender, currency, _quantity * pricePerUnit);
    }

    /// @dev Called by a Core into an Extension during the installation of the Extension.
    function onInstall(bytes calldata data) external {
        address primarySaleRecipient = abi.decode(data, (address));
        _claimableStorage().saleConfig = SaleConfig(primarySaleRecipient);
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
    function encodeBytesBeforeMintERC721(ClaimParamsERC721 memory params) external pure returns (bytes memory) {
        return abi.encode(params);
    }

    /*//////////////////////////////////////////////////////////////
                            FALLBACK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the sale configuration for a token.
    function getSaleConfig() external view returns (address primarySaleRecipient) {
        SaleConfig memory saleConfig = _claimableStorage().saleConfig;
        return (saleConfig.primarySaleRecipient);
    }

    /// @notice Sets the sale configuration for a token.
    function setSaleConfig(address _primarySaleRecipient) external {
        _claimableStorage().saleConfig = SaleConfig(_primarySaleRecipient);
    }

    /// @notice Returns the claim condition for a token.
    function getClaimCondition() external view returns (ClaimCondition memory claimCondition) {
        return _claimableStorage().claimCondition;
    }

    /// @notice Sets the claim condition for a token.
    function setClaimCondition(ClaimCondition memory _claimCondition) external {
        _claimableStorage().claimCondition = _claimCondition;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Verifies a claim against the active claim condition.
    function _validateClaimCondition(
        address _recipient,
        uint256 _amount,
        address _currency,
        uint256 _pricePerUnit,
        bytes32[] memory _allowlistProof
    ) internal {
        ClaimCondition memory condition = _claimableStorage().claimCondition;

        if (block.timestamp < condition.startTimestamp || condition.endTimestamp <= block.timestamp) {
            revert ClaimableOutOfTimeWindow();
        }

        if (_currency != condition.currency || _pricePerUnit != condition.pricePerUnit) {
            revert ClaimableIncorrectPriceOrCurrency();
        }

        if (_amount > condition.availableSupply) {
            revert ClaimableOutOfSupply();
        }

        if (condition.allowlistMerkleRoot != bytes32(0)) {
            bool isAllowlisted = MerkleProofLib.verify(
                _allowlistProof, condition.allowlistMerkleRoot, keccak256(abi.encodePacked(_recipient))
            );

            if (!isAllowlisted) {
                revert ClaimableNotInAllowlist();
            }
        }

        _claimableStorage().claimCondition.availableSupply -= _amount;
    }

    /// @dev Verifies the claim request and signature.
    function _validateClaimRequest(
        address _expectedRecipient,
        uint256 _expectedAmount,
        ClaimRequestERC721 memory _req,
        bytes memory _signature
    ) internal {
        if (_req.recipient != _expectedRecipient || _req.quantity != _expectedAmount) {
            revert ClaimableRequestMismatch();
        }

        if (block.timestamp < _req.startTimestamp || _req.endTimestamp <= block.timestamp) {
            revert ClaimableRequestOutOfTimeWindow();
        }

        if (_claimableStorage().uidUsed[_req.uid]) {
            revert ClaimableRequestUidReused();
        }

        if (_req.quantity > _claimableStorage().claimCondition.availableSupply) {
            revert ClaimableOutOfSupply();
        }

        address signer = _hashTypedData(
            keccak256(
                abi.encode(
                    TYPEHASH_CLAIMABLE_ERC721,
                    _req.startTimestamp,
                    _req.endTimestamp,
                    _req.recipient,
                    _req.quantity,
                    _req.currency,
                    _req.pricePerUnit,
                    _req.uid
                )
            )
        ).recover(_signature);

        if (!OwnableRoles(address(this)).hasAllRoles(signer, Role._MINTER_ROLE)) {
            revert ClaimableRequestUnauthorizedSignature();
        }

        _claimableStorage().uidUsed[_req.uid] = true;
        _claimableStorage().claimCondition.availableSupply -= _req.quantity;
    }

    /// @dev Distributes the mint price to the primary sale recipient and the platform fee recipient.
    function _distributeMintPrice(address _owner, address _currency, uint256 _price) internal {
        if (_price == 0) {
            if (msg.value > 0) {
                revert ClaimableIncorrectNativeTokenSent();
            }
            return;
        }

        SaleConfig memory saleConfig = _claimableStorage().saleConfig;

        if (_currency == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != _price) {
                revert ClaimableIncorrectNativeTokenSent();
            }
            SafeTransferLib.safeTransferETH(saleConfig.primarySaleRecipient, _price);
        } else {
            if (msg.value > 0) {
                revert ClaimableIncorrectNativeTokenSent();
            }
            SafeTransferLib.safeTransferFrom(_currency, _owner, saleConfig.primarySaleRecipient, _price);
        }
    }

    /// @dev Returns the domain name and version for EIP712.
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "ClaimableERC721";
        version = "1";
    }

    function _claimableStorage() internal pure returns (ClaimableStorage.Data storage) {
        return ClaimableStorage.data();
    }
}
