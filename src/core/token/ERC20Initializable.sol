// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Initializable} from "@solady/utils/Initializable.sol";

import {IERC20} from "../../interface/eip/IERC20.sol";
import {IERC20Metadata} from "../../interface/eip/IERC20Metadata.sol";
import {IERC20CustomErrors} from "../../interface/errors/IERC20CustomErrors.sol";

abstract contract ERC20Initializable is Initializable, IERC20, IERC20Metadata, IERC20CustomErrors {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The name of the token.
    string private name_;
    /// @notice The symbol of the token.
    string private symbol_;
    /// @notice The total circulating supply of tokens.
    uint256 private totalSupply_;
    /// @notice Mapping from owner address to number of owned token.
    mapping(address => uint256) private balanceOf_;
    /// @notice Mapping from owner to spender allowance.
    mapping(address => mapping(address => uint256)) private allowances_;

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    /// @dev Initializes the contract with collection name and symbol.
    function __ERC20_init(string memory _name, string memory _symbol) internal onlyInitializing {
        name_ = _name;
        symbol_ = _symbol;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The name of the token.
    function name() public view virtual override returns (string memory) {
        return name_;
    }

    /// @notice The symbol of the token.
    function symbol() public view virtual override returns (string memory) {
        return symbol_;
    }

    /// @notice Returns the number of decimals used to get its user representation.
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }

    /**
     *  @notice Returns the balance of the given address.
     *  @param _owner The address to query balance for.
     *  @return balance The quantity of tokens owned by `owner`.
     */
    function balanceOf(address _owner) public view virtual returns (uint256) {
        return balanceOf_[_owner];
    }

    /// @notice Returns the total circulating supply of tokens.
    function totalSupply() public view virtual returns (uint256) {
        return totalSupply_;
    }

    /**
     *  @notice Returns the allowance of a spender to spend a given owner's tokens.
     *  @param _owner The address that owns the tokens.
     *  @param _spender The address that is approved to spend tokens.
     *  @return allowance The quantity of tokens `spender` is allowed to spend on behalf of `owner`.
     */
    function allowance(address _owner, address _spender) public view virtual override returns (uint256) {
        return allowances_[_owner][_spender];
    }

    /*//////////////////////////////////////////////////////////////
                              EXTERNAL FUNCTIONS
      //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Approves a spender to spend tokens on behalf of an owner.
     *  @param _spender The address to approve spending on behalf of the token owner.
     *  @param _amount The quantity of tokens to approve.
     */
    function approve(address _spender, uint256 _amount) public virtual returns (bool) {
        _approve(msg.sender, _spender, _amount);

        return true;
    }

    /**
     *  @notice Transfers tokens to a recipient.
     *  @param _to The address to transfer tokens to.
     *  @param _amount The quantity of tokens to transfer.
     */
    function transfer(address _to, uint256 _amount) public virtual returns (bool) {
        if (_to == address(0)) {
            revert ERC20TransferToZeroAddress();
        }

        address _owner = msg.sender;
        uint256 _balance = balanceOf_[_owner];

        if (_balance < _amount) {
            revert ERC20TransferAmountExceedsBalance(_amount, _balance);
        }

        unchecked {
            balanceOf_[_owner] = _balance - _amount;

            // Cannot overflow because the sum of all user
            // balances can't exceed the max uint256 value.
            balanceOf_[_to] += _amount;
        }

        emit Transfer(_owner, _to, _amount);

        return true;
    }

    /**
     *  @notice Transfers tokens from a sender to a recipient.
     *  @param _from The address to transfer tokens from.
     *  @param _to The address to transfer tokens to.
     *  @param _amount The quantity of tokens to transfer.
     */
    function transferFrom(address _from, address _to, uint256 _amount) public virtual returns (bool) {
        if (_to == address(0)) {
            revert ERC20TransferToZeroAddress();
        }

        if (_from == address(0)) {
            revert ERC20TransferFromZeroAddress();
        }

        address _spender = msg.sender;
        uint256 _allowance = allowances_[_from][_spender];
        uint256 _balance = balanceOf_[_from];

        if (_allowance != type(uint256).max) {
            if (_allowance < _amount) {
                revert ERC20InsufficientAllowance(_allowance, _amount);
            }
            allowances_[_from][_spender] = _allowance - _amount;
        }

        if (_balance < _amount) {
            revert ERC20TransferAmountExceedsBalance(_amount, _balance);
        }

        unchecked {
            balanceOf_[_from] = _balance - _amount;

            // Cannot overflow because the sum of all user
            // balances can't exceed the max uint256 value.
            balanceOf_[_to] += _amount;
        }

        emit Transfer(_from, _to, _amount);

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Mints tokens to an address.
    function _mint(address _to, uint256 _amount) internal virtual {
        if (_to == address(0)) {
            revert ERC20ToZeroAddress(_to, _amount);
        }

        totalSupply_ += _amount;

        // Cannot overflow because the sum of all user
        // balances can't exceed the max uint256 value.
        unchecked {
            balanceOf_[_to] += _amount;
        }

        emit Transfer(address(0), _to, _amount);
    }

    /// @dev Burns tokens from an address.
    function _burn(address _owner, uint256 _amount) internal virtual {
        if (_owner == address(0)) {
            revert ERC20FromZeroAddress(_owner, _amount);
        }

        uint256 _balance = balanceOf_[_owner];

        if (_balance < _amount) {
            revert ERC20TransferAmountExceedsBalance(_amount, _balance);
        }

        unchecked {
            balanceOf_[_owner] = _balance - _amount;

            // Cannot underflow because a user's balance
            // will never be larger than the total supply.
            totalSupply_ -= _amount;
        }

        emit Transfer(_owner, address(0), _amount);
    }

    /// @dev Approves a spender to spend tokens on behalf of an owner.
    function _approve(address _owner, address _spender, uint256 _amount) public virtual {
        if (_owner == address(0)) {
            revert ERC20FromZeroAddress(_owner, _amount);
        }

        if (_spender == address(0)) {
            revert ERC20ToZeroAddress(_spender, _amount);
        }

        allowances_[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }
}
