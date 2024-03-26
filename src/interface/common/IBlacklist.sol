// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IBlacklist {
    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an address is blacklisted.
    error AddressIsBlacklisted(address _address, bool _isBlacklisted);

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when an address is blacklisted.
    event AddressBlacklisted(address indexed _address, bool _isBlacklisted);
   
    /*//////////////////////////////////////////////////////////////
                             EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Blacklists an address.
     *  @param _address The address to blacklist.
     */
    function blacklistAddress(address _address) external;

    /**
     *  @notice Blacklists many addresses.
     *  @param _addresses The addresses to blacklist.
     */
    function blacklistManyAddress(address[] calldata _addresses) external;

    /**
     *  @notice Unblacklists an address.
     *  @param _address The address to unblacklist.
     */
    function unblacklistAddress(address _address) external;

    /**
     *  @notice Unblacklists many addresses.
     *  @param _addresses The addresses to unblacklist.
     */
    function unblacklistManyAddress(address[] calldata _addresses) external;
    
}