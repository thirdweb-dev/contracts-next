// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.12;

import "./IAccount.sol";
import "./IAccountPermissions.sol";
import "./IMulticall.sol";

interface IAccountCore is IAccount, IAccountPermissions, IMulticall {
    /// @dev Returns the address of the factory from which the account was created.
    function factory() external view returns (address);
}