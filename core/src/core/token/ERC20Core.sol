// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import {Ownable} from "@solady/auth/Ownable.sol";
import {Multicallable} from "@solady/utils/Multicallable.sol";
import {ERC20} from "@solady/tokens/ERC20.sol";

import {HookFlagsDirectory} from "../../hook/HookFlagsDirectory.sol";
import {HookInstaller} from "../HookInstaller.sol";

import {IERC20HookInstaller} from "../../interface/IERC20HookInstaller.sol";
import {BeforeMintHookERC20} from "../../hook/BeforeMintHookERC20.sol";
import {BeforeApproveHookERC20} from "../../hook/BeforeApproveHookERC20.sol";
import {BeforeTransferHookERC20} from "../../hook/BeforeTransferHookERC20.sol";
import {BeforeBurnHookERC20} from "../../hook/BeforeBurnHookERC20.sol";

contract ERC20Core is ERC20, HookInstaller, Ownable, Multicallable, IERC20HookInstaller, HookFlagsDirectory {
    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The name of the token.
    string private name_;

    /// @notice The symbol of the token.
    string private symbol_;

    /// @notice The contract metadata URI of the contract.
    string private contractURI_;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the on initialize call fails.
    error ERC20CoreOnInitializeCallFailed();

    /// @notice Emitted when a hook initialization call fails.
    error ERC20CoreHookInitializeCallFailed();

    /// @notice Emitted when a hook call fails.
    error ERC20CoreHookCallFailed();

    /// @notice Emitted when insufficient value is sent in the constructor.
    error ERC20CoreInsufficientValueInConstructor();

    /// @notice Emitted on an attempt to mint tokens when no beforeMint hook is installed.
    error ERC20CoreMintDisabled();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the contract URI is updated.
    event ContractURIUpdated();

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Initializes the ERC20 token.
     *
     *  @param _name The name of the token.
     *  @param _symbol The symbol of the token.
     *  @param _contractURI The contract URI of the token.
     *  @param _owner The owner of the contract.
     *  @param _onInitializeCall Any external call to make on contract initialization.
     *  @param _hooksToInstall Any hooks to install and initialize on contract initialization.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address _owner,
        OnInitializeParams memory _onInitializeCall,
        InstallHookParams[] memory _hooksToInstall
    ) payable {
        // Set contract metadata
        name_ = _name;
        symbol_ = _symbol;
        _setupContractURI(_contractURI);

        // Set contract owner
        _setOwner(_owner);

        // Track native token value sent to the constructor
        uint256 constructorValue = msg.value;

        // Initialize the core token
        if (_onInitializeCall.target != address(0)) {
            if (constructorValue < _onInitializeCall.value) revert ERC20CoreInsufficientValueInConstructor();
            constructorValue -= _onInitializeCall.value;

            (bool success, bytes memory returndata) =
                _onInitializeCall.target.call{value: _onInitializeCall.value}(_onInitializeCall.data);

            if (!success) _revert(returndata, ERC20CoreOnInitializeCallFailed.selector);
        }

        // Install and initialize hooks
        for (uint256 i = 0; i < _hooksToInstall.length; i++) {
            if (constructorValue < _hooksToInstall[i].initCallValue) revert ERC20CoreInsufficientValueInConstructor();
            constructorValue -= _hooksToInstall[i].initCallValue;

            _installHook(_hooksToInstall[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the name of the token.
    function name() public view override returns (string memory) {
        return name_;
    }

    /// @notice Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return symbol_;
    }

    /**
     *  @notice Returns the contract URI of the contract.
     *  @return uri The contract URI of the contract.
     */
    function contractURI() external view returns (string memory) {
        return contractURI_;
    }

    /// @notice Returns all of the contract's hooks and their implementations.
    function getAllHooks() external view returns (ERC20Hooks memory hooks) {
        hooks = ERC20Hooks({
            beforeMint: getHookImplementation(BEFORE_MINT_ERC20_FLAG),
            beforeTransfer: getHookImplementation(BEFORE_TRANSFER_ERC20_FLAG),
            beforeBurn: getHookImplementation(BEFORE_BURN_ERC20_FLAG),
            beforeApprove: getHookImplementation(BEFORE_APPROVE_ERC20_FLAG)
        });
    }

    /*//////////////////////////////////////////////////////////////
                          EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Sets the contract URI of the contract.
     *  @dev Only callable by contract admin.
     *  @param _contractURI The contract URI to set.
     */
    function setContractURI(string memory _contractURI) external onlyOwner {
        _setupContractURI(_contractURI);
    }

    /**
     *  @notice Mints tokens. Calls the beforeMint hook.
     *  @dev Reverts if beforeMint hook is absent or unsuccessful.
     *  @param _to The address to mint the tokens to.
     *  @param _amount The amount of tokens to mint.
     *  @param _data ABI encoded data to pass to the beforeMintERC20 hook.
     */
    function mint(address _to, uint256 _amount, bytes calldata _data) external payable {
        _beforeMint(_to, _amount, _data);
        _mint(_to, _amount);
    }

    /**
     *  @notice Burns tokens.
     *  @dev Calls the beforeBurn hook. Skips calling the hook if it doesn't exist.
     *  @param _amount The amount of tokens to burn.
     *  @param _data ABI encoded arguments to pass to the beforeBurnERC20 hook.
     */
    function burn(uint256 _amount, bytes calldata _data) external {
        _beforeBurn(msg.sender, _amount, _data);
        _burn(msg.sender, _amount);
    }

    /**
     *  @notice Transfers tokens from a sender to a recipient.
     *  @param _from The address to transfer tokens from.
     *  @param _to The address to transfer tokens to.
     *  @param _amount The quantity of tokens to transfer.
     */
    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        _beforeTransfer(_from, _to, _amount);
        return super.transferFrom(_from, _to, _amount);
    }

    /**
     *  @notice Approves a spender to spend tokens on behalf of an owner.
     *  @param _spender The address to approve spending on behalf of the token owner.
     *  @param _amount The quantity of tokens to approve.
     */
    function approve(address _spender, uint256 _amount) public override returns (bool) {
        _beforeApprove(msg.sender, _spender, _amount);
        return super.approve(_spender, _amount);
    }

    /**
     * @notice Sets allowance based on token owner's signed approval.
     *
     * See https://eips.ethereum.org/EIPS/eip-2612#specification[relevant EIP
     * section].
     *
     *  @param _owner The account approving the tokens
     *  @param _spender The address to approve
     *  @param _value Amount of tokens to approve
     */
    function permit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) public override {
        _beforeApprove(_owner, _spender, _value);
        super.permit(_owner, _spender, _value, _deadline, _v, _r, _s);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether the caller can update hooks.
    function _canUpdateHooks(address _caller) internal view override returns (bool) {
        return _caller == owner();
    }

    /// @dev Returns whether the caller can write to hooks.
    function _isAuthorizedToCallHookFallbackFunction(address _caller) internal view override returns (bool) {
        return _caller == owner();
    }

    /// @dev Should return the supported hook flags.
    function _supportedHookFlags() internal view virtual override returns (uint256) {
        return BEFORE_MINT_ERC20_FLAG | BEFORE_TRANSFER_ERC20_FLAG | BEFORE_BURN_ERC20_FLAG | BEFORE_APPROVE_ERC20_FLAG;
    }

    /// @dev Sets contract URI
    function _setupContractURI(string memory _contractURI) internal {
        contractURI_ = _contractURI;
        emit ContractURIUpdated();
    }

    /*//////////////////////////////////////////////////////////////
                          HOOKS INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Calls the beforeMint hook.
    function _beforeMint(address _to, uint256 _amount, bytes calldata _data) internal virtual {
        address hook = getHookImplementation(BEFORE_MINT_ERC20_FLAG);

        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call{value: msg.value}(
                abi.encodeWithSelector(BeforeMintHookERC20.beforeMintERC20.selector, _to, _amount, _data)
            );

            if (!success) _revert(returndata, ERC20CoreHookCallFailed.selector);
        } else {
            // Revert if beforeMint hook is not installed to disable un-permissioned minting.
            revert ERC20CoreMintDisabled();
        }
    }

    /// @dev Calls the beforeTransfer hook, if installed.
    function _beforeTransfer(address _from, address _to, uint256 _amount) internal virtual {
        address hook = getHookImplementation(BEFORE_TRANSFER_ERC20_FLAG);

        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call(
                abi.encodeWithSelector(BeforeTransferHookERC20.beforeTransferERC20.selector, _from, _to, _amount)
            );
            if (!success) _revert(returndata, ERC20CoreHookCallFailed.selector);
        }
    }

    /// @dev Calls the beforeBurn hook, if installed.
    function _beforeBurn(address _from, uint256 _amount, bytes calldata _data) internal virtual {
        address hook = getHookImplementation(BEFORE_BURN_ERC20_FLAG);

        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call{value: msg.value}(
                abi.encodeWithSelector(BeforeBurnHookERC20.beforeBurnERC20.selector, _from, _amount, _data)
            );
            if (!success) _revert(returndata, ERC20CoreHookCallFailed.selector);
        }
    }

    /// @dev Calls the beforeApprove hook, if installed.
    function _beforeApprove(address _from, address _to, uint256 _amount) internal virtual {
        address hook = getHookImplementation(BEFORE_APPROVE_ERC20_FLAG);

        if (hook != address(0)) {
            (bool success, bytes memory returndata) = hook.call(
                abi.encodeWithSelector(BeforeApproveHookERC20.beforeApproveERC20.selector, _from, _to, _amount)
            );
            if (!success) _revert(returndata, ERC20CoreHookCallFailed.selector);
        }
    }
}
