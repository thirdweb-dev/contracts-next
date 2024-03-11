// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

// ====== External imports ======
import {IEntryPoint, BasePaymaster, PackedUserOperation} from "@account-abstraction/core/BasePaymaster.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";

//  ==========  Internal imports    ==========
import {IERC20} from "../../interface/eip/IERC20.sol";

/**
 * @title SimpleERC20Paymaster
 * @dev This contract allows UserOps to be sponsored with a fixed amount of ERC20 tokens instead of the native chain currency.
 * It inherits from the BasePaymaster contract and implements specific logic to handle ERC20 payments for transactions.
 */
contract SimpleERC20Paymaster is BasePaymaster {
    /*///////////////////////////////////////////////////////////////
                            State Variables
    //////////////////////////////////////////////////////////////*/

    /// @dev The ERC20 token used for payment
    IERC20 public immutable token;

    /// @dev The price per operation in the specified ERC20 tokens (in wei)
    uint256 public tokenPricePerOp;

    /*///////////////////////////////////////////////////////////////
                            Events
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Emitted when a user operation is successfully sponsored, indicating the actual token cost and gas cost.
     */
    event UserOperationSponsored(
        PostOpMode indexed mode,
        address indexed user,
        uint256 actualTokenNeeded,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    );

    /**
     * @dev Emitted when the token price per operation is updated.
     */
    event TokenPriceUpdated(uint256 oldPrice, uint256 newPrice);

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Initializes the paymaster contract with the entry point, token, and price per operation.
     * @param _entryPoint The entry point contract address for handling operations.
     * @param _token The ERC20 token address used for payments.
     * @param _tokenPricePerOp The cost per operation in tokens.
     */
    constructor(IEntryPoint _entryPoint, IERC20 _token, uint256 _tokenPricePerOp) BasePaymaster(_entryPoint) {
        token = _token;
        tokenPricePerOp = _tokenPricePerOp;
    }

    /*///////////////////////////////////////////////////////////////
                            Owner Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Allows the contract owner to update the token price per operation.
     * @param _tokenPricePerOp The new price per operation in tokens.
     */
    function setTokenPricePerOp(uint256 _tokenPricePerOp) external onlyOwner {
        emit TokenPriceUpdated(tokenPricePerOp, _tokenPricePerOp);
        tokenPricePerOp = _tokenPricePerOp;
    }

    /**
     * @dev Withdraws ERC20 tokens from the contract to a specified address, callable only by the contract owner.
     * @param to The address to which the tokens will be transferred.
     * @param amount The amount of tokens to transfer.
     */
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        SafeTransferLib.safeTransfer(address(token), to, amount);
    }

    /*///////////////////////////////////////////////////////////////
                            Paymaster Functions
    //////////////////////////////////////////////////////////////*/

    /**
     * Validate a user operation.
     * @param userOp     - The user operation.
     * @param userOpHash - The hash of the user operation.
     * @param maxCost    - The maximum cost of the user operation.
     */
    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 maxCost)
        internal
        override
        returns (bytes memory context, uint256 validationResult)
    {
        (userOpHash, maxCost); // unused

        unchecked {
            uint256 cachedTokenPrice = tokenPricePerOp;
            require(cachedTokenPrice != 0, "SPM: price not set");
            uint256 length = userOp.paymasterAndData.length - 20;
            require(
                length & 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffdf == 0,
                "SPM: invalid data length"
            );
            if (length == 32) {
                require(
                    cachedTokenPrice <= uint256(bytes32(userOp.paymasterAndData[20:52])), "SPM: token amount too high"
                );
            }
            SafeTransferLib.safeTransferFrom(address(token), userOp.sender, address(this), cachedTokenPrice);
            return (abi.encodePacked(cachedTokenPrice, userOp.sender), 0);
        }
    }

    /**
     * Post-operation handler.
     * (verified to be called only through the entryPoint)
     * @dev If subclass returns a non-empty context from validatePaymasterUserOp,
     *      it must also implement this method.
     * @param mode          - Enum with the following options:
     *                        opSucceeded - User operation succeeded.
     *                        opReverted  - User op reverted. The paymaster still has to pay for gas.
     *                        postOpReverted - never passed in a call to postOp().
     * @param context       - The context value returned by validatePaymasterUserOp
     * @param actualGasCost - Actual gas used so far (without this postOp call).
     * @param actualUserOpFeePerGas - the gas price this UserOp pays. This value is based on the UserOp's maxFeePerGas
     *                        and maxPriorityFee (and basefee)
     *                        It is not the same as tx.gasprice, which is what the bundler pays.
     */
    function _postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
        internal
        override
    {
        emit UserOperationSponsored(
            mode,
            address(bytes20(context[32:52])),
            uint256(bytes32(context[0:32])),
            actualGasCost,
            actualUserOpFeePerGas
        );
    }
}