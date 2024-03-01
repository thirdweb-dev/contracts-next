// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

library PermissionStorage {
    /// @custom:storage-location erc7201:permissions.storage
    /// @dev keccak256(abi.encode(uint256(keccak256("permission.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant PERMISSION_STORAGE_POSITION =
        0xb5e06cba4353bc00640002b636c12f4263d4ef5b2e919091e763949f55cd0d00;

    struct Data {
        /// @notice Mapping from account => permissions assigned to account.
        mapping(address => uint256) permissionBits;

        /// @notice List of permission holders.
        address[] permissionHolders;

        /// @notice Mapping from account => ever held permissions.
        mapping(address => bool) everHeldPermission;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = PERMISSION_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}
