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
contract BridgeSwapControllerWithdraw is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, IBridgeSwapController {
    using SafeERC20 for IERC20;

    IERC20 public erc20Receive;
    IERC20 public usdc;

    address public feeReceiver;
    uint256 public feeUSDCAmount;

    mapping(address => bool) public whitelistRouter;
    mapping(address => bool) public isExecutor;
    mapping(bytes swapBridgeOrder => bool approved) public orderQueue;

    constructor() {
        _disableInitializers();
    }

    /// @param _erc20Receive The address of the ERC20 token that will be used in swaps (bridge token receive).
    /// @param _usdc The address of usdc to deposit/withdraw to/from HyperLiquid
    /// @param _feeReceiver The address for fee receiver.
    /// @param _feeUSDCAmount The amount for USDC fee.
    function initialize(
        address _erc20Receive,
        address _usdc,
        address _feeReceiver,
        uint256 _feeUSDCAmount
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        erc20Receive = IERC20(_erc20Receive);
        usdc = IERC20(_usdc);
        feeReceiver = _feeReceiver;
        if (_feeUSDCAmount > 10e6) revert InvalidAmount();
        feeUSDCAmount = _feeUSDCAmount;
    }

    modifier onlyExecutor() {
        if (!isExecutor[msg.sender]) revert Unauthorized();
        _;
    }

    // swap from usdc, then bridge token for user to other chains
    function swapAndBridge(
        bytes calldata orderData,
        bytes calldata signature
    ) external nonReentrant onlyExecutor payable {
        if (orderQueue[orderData]) revert OrderExisted();
        orderQueue[orderData] = true;

        SwapBridgeData memory swapBridgeOrder = abi.decode(orderData, (SwapBridgeData));
        if (swapBridgeOrder.deadline < block.timestamp) revert Timeout();

        // Calculate user using signature
        bytes32 orderKey = keccak256(orderData);
        orderKey = ECDSA.toEthSignedMessageHash(orderKey);
        address user = ECDSA.recover(orderKey, signature);

        // claim permitted token
        uint swapAmount = swapBridgeOrder.swapAmount;
        IERC20(usdc).safePermit(user, address(this), swapAmount, swapBridgeOrder.deadline, swapBridgeOrder.permitData);
        swapAmount = _pullToken(usdc, user, swapAmount);

        if (feeReceiver != address(0) && feeUSDCAmount > 0) {
            if (swapAmount <= feeUSDCAmount) revert InvalidAmount();
            swapAmount -= feeUSDCAmount;

            usdc.safeTransfer(feeReceiver, feeUSDCAmount);
            emit FeeCollected(user, feeUSDCAmount, feeReceiver);
        }

        // execute swap
        uint balanceReceived = _executeSwap(usdc, erc20Receive, swapBridgeOrder.router, address(this), swapAmount, swapBridgeOrder.minSwapAmountOut, swapBridgeOrder.swapData);
        emit Swapped(address(this), address(erc20Receive), swapAmount, balanceReceived, block.timestamp);

        // bridge token
        (MessagingReceipt memory messagingReceipt, OFTReceipt memory oftReceipt) = IOFT(address(erc20Receive)).send{value: msg.value}(
            SendParam(swapBridgeOrder.bridgeDstEid, bytes32(uint256(uint160(user))), balanceReceived, swapBridgeOrder.minBridgeAmountOut, swapBridgeOrder.bridgeExtraOptions, new bytes(0), new bytes(0)),
            MessagingFee(msg.value, 0),
            msg.sender
        );
        if (oftReceipt.amountSentLD < balanceReceived) {
            erc20Receive.safeTransfer(user, balanceReceived - oftReceipt.amountSentLD);
        }
        emit SubmitBridge(user, balanceReceived, block.timestamp);

        emit Sent(messagingReceipt.guid, swapBridgeOrder.bridgeDstEid, user, address(usdc), swapBridgeOrder.swapAmount, feeUSDCAmount, block.timestamp);
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

    /// @dev Pulls the token from the sender.
    function _pullToken(IERC20 token, address user, uint256 amount) internal returns (uint256 amountPulled) {
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(user, address(this), amount);
        amountPulled = token.balanceOf(address(this)) - balanceBefore;
    }

    function setRouter(address _router, bool _iswhitelist) external onlyOwner {
        if (_router == address(0)) revert InvalidAddress();

        whitelistRouter[_router] = _iswhitelist;
        emit RouterSet(_router, _iswhitelist);
    }

    function setExecutor(address _executor, bool _isAdd) external onlyOwner {
        if (_executor == address(0)) revert InvalidAddress();

        isExecutor[_executor] = _isAdd;
        emit ExecutorSet(_executor, _isAdd);
    }

    function setFeeConfig(
        address _feeReceiver,
        uint256 _feeUSDCAmount
    ) external onlyOwner {
        if (feeUSDCAmount > 10e6) revert InvalidAmount();
        feeReceiver = _feeReceiver;
        feeUSDCAmount = _feeUSDCAmount;
    }
}
