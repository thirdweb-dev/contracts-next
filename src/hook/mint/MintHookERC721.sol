// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {EIP712} from "@solady/utils/EIP712.sol";
import {ECDSA} from "@solady/utils/ECDSA.sol";
import {MerkleProofLib} from "@solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";
import {Ownable} from "@solady/auth/Ownable.sol";

import {IFeeConfig} from "../../interface/common/IFeeConfig.sol";
import {IClaimCondition} from "../../interface/common/IClaimCondition.sol";
import {IMintRequest} from "../../interface/common/IMintRequest.sol";

import {ERC721Hook} from "../ERC721Hook.sol";

import {MintHookERC721Storage} from "../../storage/hook/mint/MintHookERC721Storage.sol";

contract MintHookERC721 is IFeeConfig, IMintRequest, IClaimCondition, EIP712, ERC721Hook, Multicallable {
    using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address considered as native token.
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @notice The EIP-712 typehash for the mint request struct.
    bytes32 private constant TYPEHASH = keccak256(
        "MintRequest(address minter,address token,uint256 tokenId,uint256 quantity,uint256 pricePerToken,address currency,bytes32[] allowlistProof,bytes signature,uint128 sigValidityStartTimestamp,uint128 sigValidityEndTimestamp,bytes32 sigUid,bytes auxData)"
    );

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the claim condition for a given token is updated.
    event ClaimConditionUpdate(address indexed token, ClaimCondition condition, bool resetEligibility);

    /// @notice Emitted when the next token ID to mint is updated.
    event NextTokenIdUpdate(address indexed token, uint256 nextTokenIdToMint);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when caller is not token.
    error MintHookNotToken();

    /// @notice Emitted when caller is not token core admin.
    error MintHooksNotAuthorized();

    /// @notice Emitted when minting invalid quantity.
    error MintHookInvalidQuantity(uint256 quantityToMint);

    /// @notice Emitted when minting with incorrect price.
    error MintHookInvalidPrice(uint256 expectedPrice, uint256 actualPrice);

    /// @notice Emittted when minting with invalid currency.
    error MintHookInvalidCurrency(address expectedCurrency, address actualCurrency);

    /// @notice Emitted when maximum available supply has been minted.
    error MintHookMaxSupplyClaimed();

    /// @notice Emitted when minter not in allowlist.
    error MintHookNotInAllowlist();

    /// @notice Emitted when the claim condition has not started yet.
    error MintHookMintNotStarted();

    /// @notice Emitted when the claim condition has ended.
    error MintHookMintEnded();

    /// @notice Emitted when a signature for permissioned mint is invalid
    error MintHookInvalidSignature();

    /// @notice Emitted when a permissioned mint request is expired.
    error MintHookRequestExpired();

    /// @notice Emitted when a permissioned mint request is already used.
    error MintHookRequestUsed();

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
        hookInfo.hookFlags = BEFORE_MINT_FLAG();
        hookInfo.hookFallbackFunctions = new HookFallbackFunction[](11);
        hookInfo.hookFallbackFunctions[0] =
            HookFallbackFunction({functionSelector: this.verifyClaim.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[1] = HookFallbackFunction({
            functionSelector: this.verifyPermissionedClaim.selector,
            callType: CallType.STATIC_CALL
        });
        hookInfo.hookFallbackFunctions[2] = HookFallbackFunction({
            functionSelector: this.getSupplyClaimedByWallet.selector,
            callType: CallType.STATIC_CALL
        });
        hookInfo.hookFallbackFunctions[3] =
            HookFallbackFunction({functionSelector: this.setDefaultFeeConfig.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[4] =
            HookFallbackFunction({functionSelector: this.getDefaultFeeConfig.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[5] =
            HookFallbackFunction({functionSelector: this.getClaimCondition.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[6] =
            HookFallbackFunction({functionSelector: this.setClaimCondition.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[7] =
            HookFallbackFunction({functionSelector: this.setNextIdToMint.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[8] =
            HookFallbackFunction({functionSelector: this.getNextTokenIdToMint.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[9] =
            HookFallbackFunction({functionSelector: this.getFeeConfigForToken.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[10] =
            HookFallbackFunction({functionSelector: this.setFeeConfigForToken.selector, callType: CallType.CALL});
    }

    /// @notice Returns the next token ID to mint for a given token.
    function getNextTokenIdToMint(address _token) external view returns (uint256) {
        return MintHookERC721Storage.data().nextTokenIdToMint[_token];
    }

    /// @notice Returns the active claim condition.
    function getClaimCondition(address _token) external view returns (ClaimCondition memory) {
        return MintHookERC721Storage.data().claimCondition[_token];
    }

    /**
     *  @notice Verifies that a given claim is valid.
     *
     *  @param _token The token to mint.
     *  @param _claimer The address to mint tokens for.
     *  @param _quantity The quantity of tokens to mint.
     *  @param _pricePerToken The price per token.
     *  @param _currency The currency to pay with.
     *  @param _allowlistProof The proof of the claimer's inclusion in an allowlist, if any.
     *  @return isAllowlisted Whether the claimer is allowlisted.
     */
    function verifyClaim(
        address _token,
        address _claimer,
        uint256 _quantity,
        uint256 _pricePerToken,
        address _currency,
        bytes32[] memory _allowlistProof
    ) public view virtual returns (bool isAllowlisted) {
        ClaimCondition memory currentClaimPhase = MintHookERC721Storage.data().claimCondition[_token];

        if (currentClaimPhase.startTimestamp > block.timestamp) {
            revert MintHookMintNotStarted();
        }
        if (currentClaimPhase.endTimestamp <= block.timestamp) {
            revert MintHookMintEnded();
        }

        /*
         * Here `isOverride` implies that if the merkle proof verification fails,
         * the claimer would claim through open claim limit instead of allowlisted limit.
         */
        if (currentClaimPhase.merkleRoot != bytes32(0)) {
            isAllowlisted = MerkleProofLib.verify(
                _allowlistProof, currentClaimPhase.merkleRoot, keccak256(abi.encodePacked(_claimer))
            );

            if (!isAllowlisted) {
                revert MintHookNotInAllowlist();
            }
        }

        if (_currency != currentClaimPhase.currency) {
            revert MintHookInvalidCurrency(currentClaimPhase.currency, _currency);
        }

        if (_pricePerToken != currentClaimPhase.pricePerToken) {
            revert MintHookInvalidPrice(currentClaimPhase.pricePerToken, _pricePerToken);
        }

        if (
            _quantity == 0
                || (_quantity + getSupplyClaimedByWallet(_token, _claimer) > currentClaimPhase.quantityLimitPerWallet)
        ) {
            revert MintHookInvalidQuantity(_quantity);
        }

        if (currentClaimPhase.supplyClaimed + _quantity > currentClaimPhase.maxClaimableSupply) {
            revert MintHookMaxSupplyClaimed();
        }
    }

    /**
     *  @notice Verifies that a given permissioned claim is valid
     *
     *  @param _req The mint request to check.
     */
    function verifyPermissionedClaim(MintRequest memory _req) public view returns (bool) {
        if (block.timestamp < _req.sigValidityStartTimestamp || _req.sigValidityEndTimestamp <= block.timestamp) {
            revert MintHookRequestExpired();
        }
        if (MintHookERC721Storage.data().uidUsed[_req.sigUid]) {
            revert MintHookRequestUsed();
        }

        address signer = _recoverAddress(_req);
        if (Ownable(_req.token).owner() != signer) {
            revert MintHookInvalidSignature();
        }

        return true;
    }

    /**
     *  @notice Returns the claim condition for a given token.
     *  @param _token The token to get the claim condition for.
     *  @param _claimer The address to get the supply claimed for
     */
    function getSupplyClaimedByWallet(address _token, address _claimer) public view returns (uint256) {
        MintHookERC721Storage.Data storage data = MintHookERC721Storage.data();
        return data.supplyClaimedByWallet[keccak256(abi.encode(data.conditionId[_token], _claimer))];
    }

    /// @notice Returns the fee config for a token.
    function getDefaultFeeConfig(address _token) external view returns (FeeConfig memory) {
        return MintHookERC721Storage.data().feeConfig[_token][type(uint256).max];
    }

    /// @notice Returns the fee config for a token.
    function getFeeConfigForToken(address _token, uint256 _tokenId) external view returns (FeeConfig memory) {
        return MintHookERC721Storage.data().feeConfig[_token][_tokenId];
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE MINT HOOK
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice The beforeMint hook that is called by a core token before minting a token.
     *  @param _mintRequest The request to mint tokens.
     *  @return tokenIdToMint The start tokenId to mint.
     *  @return quantityToMint The quantity of tokens to mint.
     */
    function beforeMint(MintRequest calldata _mintRequest)
        external
        payable
        override
        returns (uint256 tokenIdToMint, uint256 quantityToMint)
    {
        if (_mintRequest.token != msg.sender) {
            revert MintHookNotToken();
        }

        // Check against active claim condition unless permissioned.
        MintHookERC721Storage.Data storage data = MintHookERC721Storage.data();

        if (_mintRequest.signature.length > 0) {
            verifyPermissionedClaim(_mintRequest);
            data.uidUsed[_mintRequest.sigUid] = true;
        } else {
            verifyClaim(
                _mintRequest.token,
                _mintRequest.minter,
                _mintRequest.quantity,
                _mintRequest.pricePerToken,
                _mintRequest.currency,
                _mintRequest.allowlistProof
            );
            data.claimCondition[_mintRequest.token].supplyClaimed += _mintRequest.quantity;
            data.supplyClaimedByWallet[keccak256(abi.encode(data.conditionId[_mintRequest.token], _mintRequest.minter))]
            += _mintRequest.quantity;
        }

        tokenIdToMint = data.nextTokenIdToMint[_mintRequest.token];
        data.nextTokenIdToMint[_mintRequest.token] += _mintRequest.quantity;

        quantityToMint = _mintRequest.quantity;

        _collectPrice(
            _mintRequest.minter,
            tokenIdToMint,
            _mintRequest.pricePerToken * _mintRequest.quantity,
            _mintRequest.currency
        );
    }

    /*//////////////////////////////////////////////////////////////
                            SETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setFeeConfigForToken(uint256 _id, FeeConfig memory _config) external {
        address token = msg.sender;

        MintHookERC721Storage.data().feeConfig[token][_id] = _config;
        emit TokenFeeConfigUpdate(token, _id, _config);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setDefaultFeeConfig(FeeConfig memory _config) external {
        address token = msg.sender;

        MintHookERC721Storage.data().feeConfig[token][type(uint256).max] = _config;
        emit DefaultFeeConfigUpdate(token, _config);
    }

    /**
     *  @notice Sets the next token ID to mint for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _nextIdToMint The next token ID to mint.
     */
    function setNextIdToMint(uint256 _nextIdToMint) external {
        address token = msg.sender;

        MintHookERC721Storage.data().nextTokenIdToMint[token] = _nextIdToMint;
        emit NextTokenIdUpdate(token, _nextIdToMint);
    }

    /**
     *  @notice Sets the claim condition for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _condition The claim condition to set.
     *  @param _resetClaimEligibility Whether to reset the claim eligibility of all wallets.
     */
    function setClaimCondition(ClaimCondition calldata _condition, bool _resetClaimEligibility) external {
        address token = msg.sender;

        MintHookERC721Storage.Data storage data = MintHookERC721Storage.data();
        bytes32 targetConditionId = data.conditionId[token];
        uint256 supplyClaimedAlready = data.claimCondition[token].supplyClaimed;

        if (_resetClaimEligibility) {
            supplyClaimedAlready = 0;
            targetConditionId = keccak256(abi.encodePacked(token, targetConditionId));
        }

        if (supplyClaimedAlready > _condition.maxClaimableSupply) {
            revert MintHookMaxSupplyClaimed();
        }

        data.claimCondition[token] = ClaimCondition({
            startTimestamp: _condition.startTimestamp,
            endTimestamp: _condition.endTimestamp,
            maxClaimableSupply: _condition.maxClaimableSupply,
            supplyClaimed: supplyClaimedAlready,
            quantityLimitPerWallet: _condition.quantityLimitPerWallet,
            merkleRoot: _condition.merkleRoot,
            pricePerToken: _condition.pricePerToken,
            currency: _condition.currency,
            metadata: _condition.metadata
        });
        data.conditionId[token] = targetConditionId;

        emit ClaimConditionUpdate(token, _condition, _resetClaimEligibility);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Distributes the sale value of minting a token.
    function _collectPrice(address _minter, uint256 _tokenId, uint256 _totalPrice, address _currency) internal {
        // We want to return early when the price is 0. However, we first check if any msg value was sent incorrectly,
        // preventing native tokens from getting locked.
        if (msg.value != _totalPrice && _currency == NATIVE_TOKEN) {
            revert MintHookInvalidPrice(_totalPrice, msg.value);
        }
        if (_currency != NATIVE_TOKEN && msg.value > 0) {
            revert MintHookInvalidPrice(0, msg.value);
        }
        if (_totalPrice == 0) {
            return;
        }

        MintHookERC721Storage.Data storage data = MintHookERC721Storage.data();

        address token = msg.sender;
        FeeConfig memory defaultFeeConfig = data.feeConfig[token][type(uint256).max];
        FeeConfig memory feeConfig = data.feeConfig[token][_tokenId]; // overriden fee config

        // If there is no override-primarySaleRecipient, we will use the default primarySaleRecipient.
        if (feeConfig.primarySaleRecipient == address(0)) {
            feeConfig.primarySaleRecipient = defaultFeeConfig.primarySaleRecipient;
        }

        // If there is no override-platformFeeRecipient, we will use the default platformFee recipient and bps.
        if (feeConfig.platformFeeRecipient == address(0)) {
            feeConfig.platformFeeRecipient = defaultFeeConfig.platformFeeRecipient;
            feeConfig.platformFeeBps = defaultFeeConfig.platformFeeBps;
        }

        uint256 platformFees = (_totalPrice * feeConfig.platformFeeBps) / 10_000;

        if (_currency == NATIVE_TOKEN) {
            if (platformFees > 0) {
                SafeTransferLib.safeTransferETH(feeConfig.platformFeeRecipient, platformFees);
            }
            SafeTransferLib.safeTransferETH(feeConfig.primarySaleRecipient, _totalPrice - platformFees);
        } else {
            if (platformFees > 0) {
                SafeTransferLib.safeTransferFrom(_currency, _minter, feeConfig.platformFeeRecipient, platformFees);
            }
            SafeTransferLib.safeTransferFrom(
                _currency, _minter, feeConfig.primarySaleRecipient, _totalPrice - platformFees
            );
        }
    }

    /// @dev Returns the domain name and version for the EIP-712 domain separator
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "MintHookERC721";
        version = "1";
    }

    /// @dev Returns the address of the signer of the mint request.
    function _recoverAddress(MintRequest memory _req) internal view returns (address) {
        return _hashTypedData(keccak256(_encodeRequest(_req))).recover(_req.signature);
    }

    /// @dev Encodes the typed data struct.
    function _encodeRequest(MintRequest memory _req) internal view returns (bytes memory) {
        return abi.encode(
            TYPEHASH,
            _req.minter,
            _req.token,
            _req.tokenId,
            _req.quantity,
            _req.pricePerToken,
            _req.currency,
            _req.allowlistProof,
            keccak256(bytes("")),
            _req.sigValidityStartTimestamp,
            _req.sigValidityEndTimestamp,
            _req.sigUid,
            keccak256(_req.auxData)
        );
    }
}
