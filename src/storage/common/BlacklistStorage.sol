// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

library BlacklistStorage {
    /// @custom:storage-location erc7201:blacklist.storage
    /// @dev keccak256(abi.encode(uint256(keccak256("blacklist.storage")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 public constant BLACKLIST_STORAGE_POSITION =
        0xde72c4a458f25b5a7f48ff4da2dc30170c35dc8d492ce5968aa87a2703855100;

    struct Data {
        /// @dev Mapping from address to whether the address is blacklisted.
         mapping(address => bool)  isBlacklisted;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = BLACKLIST_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}