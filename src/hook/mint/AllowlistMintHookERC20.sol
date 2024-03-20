// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {MerkleProofLib} from "@solady/utils/MerkleProofLib.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";

import {IFeeConfig} from "../../interface/common/IFeeConfig.sol";

import {ERC20Hook} from "../ERC20Hook.sol";

import {AllowlistMintHookERC20Storage} from "../../storage/hook/mint/AllowlistMintHookERC20Storage.sol";

contract AllowlistMintHookERC20 is IFeeConfig, ERC20Hook, Multicallable {
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
        __ERC20Hook_init(_upgradeAdmin);
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
        hookInfo.hookFallbackFunctions = new HookFallbackFunction[](4);
        hookInfo.hookFallbackFunctions[0] =
            HookFallbackFunction({functionSelector: this.getFeeConfig.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[1] =
            HookFallbackFunction({functionSelector: this.getClaimCondition.selector, callType: CallType.STATIC_CALL});
        hookInfo.hookFallbackFunctions[2] =
            HookFallbackFunction({functionSelector: this.setClaimCondition.selector, callType: CallType.CALL});
        hookInfo.hookFallbackFunctions[3] =
            HookFallbackFunction({functionSelector: this.setDefaultFeeConfig.selector, callType: CallType.CALL});
    }

    /// @notice Returns the fee config for a token.
    function getFeeConfig(address _token) external view returns (FeeConfig memory) {
        return AllowlistMintHookERC20Storage.data().feeConfig[_token];
    }

    /// @notice Returns the active claim condition.
    function getClaimCondition(address _token) external view returns (ClaimCondition memory) {
        return AllowlistMintHookERC20Storage.data().claimCondition[_token];
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE MINT hook
    //////////////////////////////////////////////////////////////*/

    error AllowlistMintHookNotToken();

    /**
     *  @notice The beforeMint hook that is called by a core token before minting a token.
     *  @param _mintRequest The token mint request details.
     *  @return quantityToMint The quantity of tokens to mint.
     */
    function beforeMint(MintRequest calldata _mintRequest)
        external
        payable
        virtual
        override
        returns (uint256 quantityToMint)
    {
        address token = msg.sender;
        if (_mintRequest.token != msg.sender) {
            revert AllowlistMintHookNotToken();
        }

        AllowlistMintHookERC20Storage.Data storage data = AllowlistMintHookERC20Storage.data();

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

        quantityToMint = uint96(_mintRequest.quantity);
        // `price` is interpreted as price per 1 ether unit of the ERC20 tokens.
        uint256 totalPrice = (_mintRequest.quantity * condition.price) / 1 ether;

        data.claimCondition[token].availableSupply -= _mintRequest.quantity;

        _collectPrice(totalPrice);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Sets the claim condition for a given token.
     *  @dev Only callable by an admin of the given token.
     *  @param _claimCondition The claim condition to set.
     */
    function setClaimCondition(ClaimCondition memory _claimCondition) public {
        address token = msg.sender;

        AllowlistMintHookERC20Storage.data().claimCondition[token] = _claimCondition;
        emit ClaimConditionUpdate(token, _claimCondition);
    }

    /**
     *  @notice Sets the fee config for a given token.
     *  @param _config The fee config for the token.
     */
    function setDefaultFeeConfig(FeeConfig memory _config) external {
        address token = msg.sender;

        AllowlistMintHookERC20Storage.data().feeConfig[token] = _config;
        emit DefaultFeeConfigUpdate(token, _config);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Distributes the sale value of minting a token.
    function _collectPrice(uint256 _totalPrice) internal {
        if (msg.value != _totalPrice) {
            revert AllowlistMintHookIncorrectValueSent();
        }
        if (_totalPrice == 0) {
            return;
        }

        address token = msg.sender;
        FeeConfig memory feeConfig = AllowlistMintHookERC20Storage.data().feeConfig[token];

        uint256 platformFees = 0;
        if (feeConfig.platformFeeRecipient != address(0)) {
            platformFees = (_totalPrice * feeConfig.platformFeeBps) / 10_000;
        }
        if (platformFees > 0) {
            SafeTransferLib.safeTransferETH(feeConfig.platformFeeRecipient, platformFees);
        }
        SafeTransferLib.safeTransferETH(feeConfig.primarySaleRecipient, _totalPrice - platformFees);
    }
}
