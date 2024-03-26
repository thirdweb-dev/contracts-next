// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { ERC1155Hook } from "../ERC1155Hook.sol";
import { IPermission } from "../../interface/common/IPermission.sol";
import { Blacklist } from "../../common/Blacklist.sol";

contract BlacklistHookERC1155 is Blacklist, ERC1155Hook {

    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when caller is not token.
    error BeforeTransferHookNotToken();

    // /// @notice Emitted when caller is not authorized.
    // error BeforeTransferHookNotAuthorized();
    
    /*//////////////////////////////////////////////////////////////
                                INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function initialize(address _upgradeAdmin) public initializer {
        __ERC1155Hook_init(_upgradeAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getHooks() external pure override returns (uint256) {
        return BEFORE_TRANSFER_FLAG();
    }


    /*//////////////////////////////////////////////////////////////
                            BEFORE TRANSFER HOOK
    //////////////////////////////////////////////////////////////*/

    function beforeTransfer(
        address from,
        address to,
        uint256, // space holder for id
        uint256 // space holder for value
    ) external override {
        address token = msg.sender;
        if (token != msg.sender) {
            revert BeforeTransferHookNotToken();
        }

        if (isBlacklisted(to)) {
            revert AddressIsBlacklisted(to, isBlacklisted(to));
        }
        if (isBlacklisted(from)) {
            revert AddressIsBlacklisted(from, isBlacklisted(from));
        }
    }
}