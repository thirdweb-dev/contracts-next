// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {MerkleProofLib} from "@solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";

import {IFeeConfig} from "../../interface/common/IFeeConfig.sol";

import {ERC721Hook} from "../ERC721Hook.sol";

import {AllowlistMintHookERC721Storage} from "../../storage/hook/mint/AllowlistMintHookERC721Storage.sol";

contract AllowlistMintHookERC721 is IFeeConfig, ERC721Hook, Multicallable {
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
    event ClaimConditionUpdate(address indexed token, ClaimCondition claimCondition);

    /// @notice Emitted when the next token ID to mint is updated.
    event NextTokenIdUpdate(address indexed token, uint256 nextTokenIdToMint);

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when caller is not token core admin.
    error AllowlistMintHooksNotAuthorized();

    /// @notice Emitted on an attempt to mint when the claimer is not in the allowlist.
    error AllowlistMintHookNotInAllowlist(address token, address claimer);

    /// @notice Emitted when incorrect native token value is sent.
    error AllowlistMintHookIncorrectValueSent();

    /// @notice Emitted when minting invalid quantity of tokens.
    error AllowlistMintHookInvalidQuantity();

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The address considered as native token.
    address public constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

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
        hookInfo.hookFallbackFunctions = new HookFallbackFunction[](8);
        hookInfo.hookFallbackFunctions[0] =
            HookFallbackFunction({functionSelector: this.setFeeConfigForToken.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[1] =
            HookFallbackFunction({functionSelector: this.getDefaultFeeConfig.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[2] =
            HookFallbackFunction({functionSelector: this.getClaimCondition.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[3] =
            HookFallbackFunction({functionSelector: this.setClaimCondition.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[4] =
            HookFallbackFunction({functionSelector: this.setNextIdToMint.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[5] =
            HookFallbackFunction({functionSelector: this.getNextTokenIdToMint.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[6] =
            HookFallbackFunction({functionSelector: this.getFeeConfigForToken.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[7] =
            HookFallbackFunction({functionSelector: this.setDefaultFeeConfig.selector, callType: CallType.CALL});
    }

    /// @notice Returns the next token ID to mint for a given token.
    function getNextTokenIdToMint(address _token) external view returns (uint256) {
        return AllowlistMintHookERC721Storage.data().nextTokenIdToMint[_token];
    }

    /// @notice Returns the fee config for a token.
    function getFeeConfigForToken(address _token, uint256 _id) external view returns (FeeConfig memory) {
        return AllowlistMintHookERC721Storage.data().feeConfig[_token][_id];
    }

    /// @notice Returns the fee config for a token.
    function getDefaultFeeConfig(address _token) external view returns (FeeConfig memory) {
        return AllowlistMintHookERC721Storage.data().feeConfig[_token][type(uint256).max];
    }

    /// @notice Returns the active claim condition.
    function getClaimCondition(address _token) external view returns (ClaimCondition memory) {
        return AllowlistMintHookERC721Storage.data().claimCondition[_token];
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE MINT hook
    //////////////////////////////////////////////////////////////*/

    error AllowlistMintHookNotToken();

    /**
     *  @notice The beforeMint hook that is called by a core token before minting a token.
     *  @param _mintRequest The request to mint tokens.
     *  @return tokenIdToMint The start tokenId to mint.
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

        AllowlistMintHookERC721Storage.Data storage data = AllowlistMintHookERC721Storage.data();

        ClaimCondition memory condition = data.claimCondition[token];

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

        tokenIdToMint = data.nextTokenIdToMint[token];
        data.nextTokenIdToMint[token] += _mintRequest.quantity;

        quantityToMint = _mintRequest.quantity;

        data.claimCondition[token].availableSupply -= _mintRequest.quantity;

        _collectPrice(condition.price * _mintRequest.quantity, tokenIdToMint);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Sets the next token ID to mint for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _nextIdToMint The next token ID to mint.
     */
    function setNextIdToMint(uint256 _nextIdToMint) external {
        address token = msg.sender;

        AllowlistMintHookERC721Storage.data().nextTokenIdToMint[token] = _nextIdToMint;
        emit NextTokenIdUpdate(token, _nextIdToMint);
    }

    /**
     *  @notice Sets the claim condition for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _claimCondition The claim condition to set.
     */
    function setClaimCondition(ClaimCondition memory _claimCondition) public {
        address token = msg.sender;

        AllowlistMintHookERC721Storage.data().claimCondition[token] = _claimCondition;
        emit ClaimConditionUpdate(token, _claimCondition);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setFeeConfigForToken(uint256 _id, FeeConfig memory _config) external {
        address token = msg.sender;

        AllowlistMintHookERC721Storage.data().feeConfig[token][_id] = _config;
        emit TokenFeeConfigUpdate(token, _id, _config);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setDefaultFeeConfig(FeeConfig memory _config) external {
        address token = msg.sender;

        AllowlistMintHookERC721Storage.data().feeConfig[token][type(uint256).max] = _config;
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

        AllowlistMintHookERC721Storage.Data storage data = AllowlistMintHookERC721Storage.data();

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
