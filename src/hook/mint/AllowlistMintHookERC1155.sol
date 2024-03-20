// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {MerkleProofLib} from "@solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";

import {IFeeConfig} from "../../interface/common/IFeeConfig.sol";

import {ERC1155Hook} from "../ERC1155Hook.sol";

import {AllowlistMintHookERC1155Storage} from "../../storage/hook/mint/AllowlistMintHookERC1155Storage.sol";

contract AllowlistMintHookERC1155 is IFeeConfig, ERC1155Hook, Multicallable {
    /*//////////////////////////////////////////////////////////////
                               STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice The claim conditions for minting a token.
     *  @param price The price of minting one token.
     *  @param availableSupply The number of tokens that can be minted.
     *  @param allowlistMerkleRoot The allowlist of minters who are eligible to mint tokens
     */
    struct ClaimCondition {
        uint256 price;
        uint256 availableSupply;
        bytes32 allowlistMerkleRoot;
    }

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the claim condition for a given token is updated.
    event ClaimConditionUpdate(address indexed token, uint256 id, ClaimCondition claimCondition);

    /// @notice Emitted when the next token ID to mint is updated.
    event NextTokenIdUpdate(address indexed token, uint256 nextTokenIdToMint);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when caller is not token core admin.
    error AllowlistMintHooksNotAuthorized();

    /// @notice Emitted when minting invalid quantity of tokens.
    error AllowlistMintHookInvalidQuantity();

    /// @notice Emitted on an attempt to mint when the claimer is not in the allowlist.
    error AllowlistMintHookNotInAllowlist(address token, address claimer);

    /// @notice Emitted when incorrect native token value is sent.
    error AllowlistMintHookIncorrectValueSent();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address considered as native token.
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*//////////////////////////////////////////////////////////////
                                INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function initialize(address _upgradeAdmin) public initializer {
        __ERC1155Hook_init(_upgradeAdmin);
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
        hookInfo.hookFallbackFunctions = new HookFallbackFunction[](6);
        hookInfo.hookFallbackFunctions[0] =
            HookFallbackFunction({functionSelector: this.getFeeConfigForToken.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[1] =
            HookFallbackFunction({functionSelector: this.getClaimCondition.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[2] =
            HookFallbackFunction({functionSelector: this.setClaimCondition.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[3] =
            HookFallbackFunction({functionSelector: this.setDefaultFeeConfig.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[4] =
            HookFallbackFunction({functionSelector: this.setFeeConfigForToken.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[5] =
            HookFallbackFunction({functionSelector: this.getDefaultFeeConfig.selector, callType: CallType.STATIC_CALL});
    }

    /// @notice Returns the fee config for a token.
    function getFeeConfigForToken(address _token, uint256 _id) external view returns (FeeConfig memory) {
        return AllowlistMintHookERC1155Storage.data().feeConfig[_token][_id];
    }

    /// @notice Returns the fee config for a token.
    function getDefaultFeeConfig(address _token) external view returns (FeeConfig memory) {
        return AllowlistMintHookERC1155Storage.data().feeConfig[_token][type(uint256).max];
    }

    /// @notice Returns the active claim condition.
    function getClaimCondition(address _token, uint256 _id) external view returns (ClaimCondition memory) {
        return AllowlistMintHookERC1155Storage.data().claimCondition[_token][_id];
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE MINT hook
    //////////////////////////////////////////////////////////////*/

    error AllowlistMintHookNotToken();

    /**
     *  @notice The beforeMint hook that is called by a core token before minting a token.
     *  @param _mintRequest The token mint request details.
     *  @return tokenIdToMint The tokenId to mint.
     *  @return quantityToMint The quantity of tokens to mint.
     */
    function beforeMint(MintRequest calldata _mintRequest)
        external
        payable
        virtual
        override
        returns (uint256 tokenIdToMint, uint256 quantityToMint)
    {
        address token = msg.sender;
        if (_mintRequest.token != msg.sender) {
            revert AllowlistMintHookNotToken();
        }

        AllowlistMintHookERC1155Storage.Data storage data = AllowlistMintHookERC1155Storage.data();

        ClaimCondition memory condition = data.claimCondition[token][_mintRequest.tokenId];

        if (_mintRequest.quantity == 0 || _mintRequest.quantity > condition.availableSupply) {
            revert AllowlistMintHookInvalidQuantity();
        }

        if (condition.allowlistMerkleRoot != bytes32(0)) {
            bytes32[] memory allowlistProof = _mintRequest.allowlistProof;

            bool isAllowlisted = MerkleProofLib.verify(
                allowlistProof, condition.allowlistMerkleRoot, keccak256(abi.encodePacked(_mintRequest.minter))
            );
            if (!isAllowlisted) {
                revert AllowlistMintHookNotInAllowlist(token, _mintRequest.minter);
            }
        }

        tokenIdToMint = _mintRequest.tokenId;
        quantityToMint = _mintRequest.quantity;

        data.claimCondition[token][_mintRequest.tokenId].availableSupply -= _mintRequest.quantity;

        _collectPrice(condition.price * _mintRequest.quantity, _mintRequest.tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Sets the claim condition for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _claimCondition The claim condition to set.
     */
    function setClaimCondition(uint256 _id, ClaimCondition memory _claimCondition) public {
        address token = msg.sender;

        AllowlistMintHookERC1155Storage.data().claimCondition[token][_id] = _claimCondition;
        emit ClaimConditionUpdate(token, _id, _claimCondition);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setFeeConfigForToken(uint256 _id, FeeConfig memory _config) external {
        address token = msg.sender;

        AllowlistMintHookERC1155Storage.data().feeConfig[token][_id] = _config;
        emit TokenFeeConfigUpdate(token, _id, _config);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setDefaultFeeConfig(FeeConfig memory _config) external {
        address token = msg.sender;

        AllowlistMintHookERC1155Storage.data().feeConfig[token][type(uint256).max] = _config;
        emit DefaultFeeConfigUpdate(token, _config);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Distributes the sale value of minting a token.
    function _collectPrice(uint256 _totalPrice, uint256 _id) internal {
        if (msg.value != _totalPrice) {
            revert AllowlistMintHookIncorrectValueSent();
        }
        if (_totalPrice == 0) {
            return;
        }

        AllowlistMintHookERC1155Storage.Data storage data = AllowlistMintHookERC1155Storage.data();

        address token = msg.sender;
        FeeConfig memory defaultFeeConfig = data.feeConfig[token][type(uint256).max];
        FeeConfig memory feeConfig = data.feeConfig[token][_id]; // overriden fee config

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
        if (platformFees > 0) {
            SafeTransferLib.safeTransferETH(feeConfig.platformFeeRecipient, platformFees);
        }
        SafeTransferLib.safeTransferETH(feeConfig.primarySaleRecipient, _totalPrice - platformFees);
    }
}
