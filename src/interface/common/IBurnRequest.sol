// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IBurnRequest {
    /**
     *  @notice Represents a burn request on a Burn hook.
     *
     *  @param token The address of the token to be burned.
     *  @param tokenId The id of the token to be burned. Ingnored for ERC-20 and ERC-721 burn hooks.
     *  @param owner The address of the owner.
     *  @param quantity The quantity of tokens to be burned.
     *  @param permissionSignature The signature of the token contract admin authorizing burning of tokens.
     *  @param sigValidityStartTimestamp The timestamp from which the signature is valid.
     *  @param sigValidityEndTimestamp The timestamp until which the signature is valid.
     *  @param sigUid The unique id of the signature.
     */
    struct BurnRequest {
        address token;
        uint256 tokenId;
        address owner;
        uint256 quantity;
        bytes permissionSignature;
        uint128 sigValidityStartTimestamp;
        uint128 sigValidityEndTimestamp;
        bytes32 sigUid;
    }
}
