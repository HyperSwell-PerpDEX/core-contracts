pragma solidity 0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { IOAppComposer } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppComposer.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { IOFT, SendParam, OFTReceipt } from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import { MessagingReceipt, MessagingFee } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import "./interfaces/IBridgeSwapController.sol";
import "./interfaces/IHyperLiquidDepositBridge.sol";
import "./lib/LibUtil.sol";
import {SafeERC20} from "./lib/SafeERC20.sol";

// support 2 flow of bridge (via layer zero) + swap:
// 1: receive token bridge and swap to user address
// 2: swap token and bridge to user address
contract BridgeSwapControllerDeposit is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IBridgeSwapController {
    using SafeERC20 for IERC20;

    IERC20 public erc20Receive;
    IERC20 public usdc;
    address public endpoint;
    address public oApp;
    address public hyperLiquidDeposit;

    mapping(address => bool) public whitelistRouter;

    constructor() {
        _disableInitializers();
    }

    /// @param _erc20Receive The address of the ERC20 token that will be used in swaps (bridge token receive).
    /// @param _usdc The address of usdc to deposit/withdraw to/from HyperLiquid
    /// @param _endpoint LayerZero Endpoint address
    /// @param _oApp The address of the OApp that is sending the composed message.
    /// @param _hyperLiquidDeposit The address of the Hyper Liquid bridge.
    function initialize(
        address _erc20Receive,
        address _usdc,
        address _endpoint,
        address _oApp,
        address _hyperLiquidDeposit
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        erc20Receive = IERC20(_erc20Receive);
        usdc = IERC20(_usdc);
        endpoint = _endpoint;
        oApp = _oApp;
        hyperLiquidDeposit = _hyperLiquidDeposit;
    }

    /// @notice Handles incoming composed messages from LayerZero.
    /// @dev Decodes the message payload to perform a token swap.
    ///      This method expects the encoded compose message to contain the swap amount and recipient address.
    ///      Use bridged token to swap to usdc for user, then deposit to HyperLiquid. if swap not success, send bridged token to user
    /// @param _oApp The address of the originating OApp.
    /// @param _guid The globally unique identifier of the message.
    /// @param _message The encoded message content in the format of the OFTComposeMsgCodec.
    /// @param _executor Executor address.
    /// @param _executorData Additional data for checking for a specific executor.
    function lzCompose(
        address _oApp,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _executorData
    ) external nonReentrant payable {
        require(_oApp == oApp, "!oApp");
        require(msg.sender == endpoint, "!endpoint");

        // Extract the composed message from the delivered message using the MsgCodec
        uint256 _amountLD = OFTComposeMsgCodec.amountLD(_message);
        address fromAddress = address(uint160(uint256(OFTComposeMsgCodec.composeFrom(_message))));
        emit Bridged(fromAddress, _amountLD, block.timestamp);

        BridgeSwapData memory bridgeSwapData;
        // if fromUser submit this txn, use executor data swap
        if (fromAddress == _executor) {
            bridgeSwapData = abi.decode(_executorData, (BridgeSwapData));
        } else {
            bridgeSwapData = abi.decode(OFTComposeMsgCodec.composeMsg(_message), (BridgeSwapData));
        }

        // execute swap
        uint balanceReceived = _executeSwap(erc20Receive, usdc, bridgeSwapData.router, fromAddress, _amountLD, bridgeSwapData.minAmountOut, bridgeSwapData.swapData);
        emit Swapped(fromAddress, address(usdc), _amountLD, balanceReceived, block.timestamp);

        // deposit to Hyper Liquid with permit data
        IERC20(usdc).safePermit(fromAddress, address(this), bridgeSwapData.amountPermit, bridgeSwapData.deadline, bridgeSwapData.permitData);
        usdc.safeTransferFrom(fromAddress, hyperLiquidDeposit, balanceReceived);
        emit DepositedToHyperLiquid(fromAddress, balanceReceived, block.timestamp);

        emit Received(_guid, fromAddress, address(erc20Receive), balanceReceived, block.timestamp);
    }

    function _executeSwap(
        IERC20 inputToken, IERC20 outputToken, address router, address receiver, uint256 amountSwap, uint256 minAmountOut, bytes memory swapData
    ) internal returns (uint256 balanceReceived) {
        // Execute the token swap
        if (!whitelistRouter[router]) revert InvalidAddress();
        if (minAmountOut < 1) revert InvalidAmount();

        uint balanceBefore = outputToken.balanceOf(receiver);

        inputToken.safeIncreaseAllowance(router, amountSwap);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory res) = router.call(swapData);
        if (!success) {
            string memory reason = LibUtil.getRevertMsg(res);
            revert(string(abi.encodePacked("swap reverted:", reason)));
        }

        balanceReceived = outputToken.balanceOf(receiver) - balanceBefore;
        if (balanceReceived < minAmountOut) revert SwapSlippage();
    }

    function setRouter(address _router, bool _iswhitelist) external onlyOwner {
        if (_router == address(0)) revert InvalidAddress();

        whitelistRouter[_router] = _iswhitelist;
        emit RouterSet(_router, _iswhitelist);
    }
}
