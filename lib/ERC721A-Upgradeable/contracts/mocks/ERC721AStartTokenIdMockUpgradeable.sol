// SPDX-License-Identifier: MIT
// ERC721A Contracts v4.3.0
// Creators: Chiru Labs

pragma solidity ^0.8.4;

import './ERC721AMockUpgradeable.sol';
import './StartTokenIdHelperUpgradeable.sol';
import '../ERC721A__Initializable.sol';

contract ERC721AStartTokenIdMockUpgradeable is
    ERC721A__Initializable,
    StartTokenIdHelperUpgradeable,
    ERC721AMockUpgradeable
{
    function __ERC721AStartTokenIdMock_init(
        string memory name_,
        string memory symbol_,
        uint256 startTokenId_
    ) internal onlyInitializingERC721A {
        __StartTokenIdHelper_init_unchained(startTokenId_);
        __ERC721A_init_unchained(name_, symbol_);
        __DirectBurnBitSetterHelper_init_unchained();
        __ERC721AMock_init_unchained(name_, symbol_);
        __ERC721AStartTokenIdMock_init_unchained(name_, symbol_, startTokenId_);
    }

    function __ERC721AStartTokenIdMock_init_unchained(
        string memory,
        string memory,
        uint256
    ) internal onlyInitializingERC721A {}

    function _startTokenId() internal view override returns (uint256) {
        return startTokenId();
    }
}
