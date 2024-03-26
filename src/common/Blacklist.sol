// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { IBlacklist } from "../interface/common/IBlacklist.sol";
import { BlacklistStorage } from "../storage/common/BlacklistStorage.sol";

contract Blacklist is IBlacklist {

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function isBlacklisted(address _address) public view  returns (bool) {
        return BlacklistStorage.data().isBlacklisted[_address];
    }


    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function blacklistAddress(address _address) external  {
        BlacklistStorage.Data storage data = BlacklistStorage.data();
        data.isBlacklisted[_address] = true;
        emit AddressBlacklisted(_address, true);
    }

    function blacklistManyAddress(address[] calldata _addresses) external {
       BlacklistStorage.Data storage data = BlacklistStorage.data();
       for (uint i = 0; i < _addresses.length; i++) {
            data.isBlacklisted[_addresses[i]] = true;
            emit AddressBlacklisted(_addresses[i], true);
        }
    }

    function unblacklistAddress(address _address) external  {
        BlacklistStorage.Data storage data = BlacklistStorage.data();
        if (data.isBlacklisted[_address]) { // Check if the address is currently blacklisted
                data.isBlacklisted[_address] = false;
                emit AddressBlacklisted(_address, false);
        }
    }

    function unblacklistManyAddress(address[] calldata _addresses) external {
         BlacklistStorage.Data storage data = BlacklistStorage.data();
        for (uint i = 0; i < _addresses.length; i++) {
            if (data.isBlacklisted[_addresses[i]]) { // Check if the address is currently blacklisted
                data.isBlacklisted[_addresses[i]] = false;
                emit AddressBlacklisted(_addresses[i], false);
            }
        }
    }

}