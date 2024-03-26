// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { ERC1155Hook } from "../ERC1155Hook.sol";
import { EIP712 } from "@solady/utils/EIP712.sol";
import { ECDSA } from "@solady/utils/ECDSA.sol";

import { IPermission } from "../../interface/common/IPermission.sol";
import { IBurnRequest } from "../../interface/common/IBurnRequest.sol";


import { BurnHookERC1155Storage } from "../../storage/hook/burn/BurnHookERC1155Storage.sol";

contract BurnHookERC1155 is IBurnRequest, EIP712, ERC1155Hook {
   using ECDSA for bytes32;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The EIP-712 typehash for the burn request struct.
    bytes32 private constant TYPEHASH =
        keccak256(
            "BurnRequest(address token,uint256 tokenId,address owner,uint256 quantity,bytes permissionSignature,uint128 sigValidityStartTimestamp,uint128 sigValidityEndTimestamp,bytes32 sigUid)"
        );


    /*//////////////////////////////////////////////////////////////
                               ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Error when the signature is invalid.
    error BurnHookInvalidSignature();

    /// @notice Error when the request has expired.
    error BurnHookRequestExpired();

    /// @notice Error when the request has been used.
    error BurnHookRequestUsed();

    /// @notice Error when the recipient is invalid.
    error BurnHookInvalidRecipient();

    /// @notice Error when the token is invalid.
    error BurnHookNotToken();

    /// @notice Error when the quantity is invalid.
    error BurnHookInvalidQuantity(uint256 _quantity);

    /// @notice Error when the token ID is invalid.
    error BurnHookInvalidTokenId(uint256 _tokenId);

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
        return BEFORE_BURN_FLAG();
    }

    /// @notice Returns the signature of the arguments expected by the beforeBurn hook.
    function getBeforeBurnArgSignature() external pure override returns (string memory argSignature) {
        argSignature = "address,uint256,address,uint256,bytes,uint128,uint128,bytes32,";
    }

    /// @dev Returns the domain name and version for the EIP-712 domain separator
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "BurnHookERC1155";
        version = "1";
    }

    /*//////////////////////////////////////////////////////////////
                            BEFORE BURN HOOK
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice The beforeBurn hook that is called by a core token before burning a token.
     *  @param _from The address that is burning tokens.
     *  @param _id The token ID being burned.
     *  @param _value The quantity of tokens being burned.
     *  @param _encodedArgs The encoded arguments for the beforeBurn hook.
     */
    function beforeBurn(
        address _from,
        uint256 _id,
        uint256 _value,
        bytes memory _encodedArgs
    ) external override {
        BurnRequest memory req = abi.decode(_encodedArgs, (BurnRequest));
        
        if (req.token != msg.sender) {
            revert BurnHookNotToken();
        }

        if (req.quantity != _value) {
            revert BurnHookInvalidQuantity(_value);
        }

        if (req.owner != _from) {
            revert BurnHookInvalidRecipient();
        }
        if (req.tokenId != _id) {
            revert BurnHookInvalidTokenId(_id);
        }

        if (req.permissionSignature.length <= 0) {
             revert BurnHookInvalidSignature();
        }  
        
        BurnHookERC1155Storage.Data storage data = BurnHookERC1155Storage.data();
        verifyPermissionedClaim(req);
        data.uidUsed[req.sigUid] = true;
        
    }

    /*//////////////////////////////////////////////////////////////
                            SIGNATURE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Verifies that a given permissioned claim is valid
     *
     *  @param _req The burn request to check.
     */
    function verifyPermissionedClaim(BurnRequest memory _req) public view returns (bool) {
        if (block.timestamp < _req.sigValidityStartTimestamp || _req.sigValidityEndTimestamp <= block.timestamp) {
            revert BurnHookRequestExpired();
        }
        if (BurnHookERC1155Storage.data().uidUsed[_req.sigUid]) {
            revert BurnHookRequestUsed();
        }

        address signer = _recoverAddress(_req);
        if (!IPermission(_req.token).hasRole(signer, ADMIN_ROLE_BITS)) {
            revert BurnHookInvalidSignature();
        }

        return true;
    }

    /// @dev Returns the address of the signer of the burn request.
    function _recoverAddress(BurnRequest memory _req) internal view returns (address) {
        return
            _hashTypedData(
                keccak256(
                    abi.encode(
                        TYPEHASH,
                        _req.token,
                        _req.tokenId,
                        _req.owner,
                        _req.quantity,
                        keccak256(bytes("")),
                        _req.sigValidityStartTimestamp,
                        _req.sigValidityEndTimestamp,
                        _req.sigUid
                    )
                )
            ).recover(_req.permissionSignature);
    }
}
