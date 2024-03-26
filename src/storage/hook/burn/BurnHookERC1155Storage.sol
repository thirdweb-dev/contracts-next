// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { BurnHookERC1155 } from "../../../hook/burn/BurnHookERC1155.sol";
import { IClaimCondition } from "../../../interface/common/IClaimCondition.sol";
import { IFeeConfig } from "../../../interface/common/IFeeConfig.sol";

library BurnHookERC1155Storage {
    /// @custom:storage-location erc7201:burn.hook.erc1155.storage
    /// @dev keccak256(abi.encode(uint256(keccak256("burn.hook.erc1155.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant BURN_HOOK_ERC1155_STORAGE_POSITION =
        0x9dba7bf1a1a69a0404002647b9ae71814c164e94c530a544d28db5298de88000;

    struct Data {
        /// @dev Mapping from permissioned burn request UID => whether the burn request is processed.
        mapping(bytes32 => bool) uidUsed;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = BURN_HOOK_ERC1155_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}
