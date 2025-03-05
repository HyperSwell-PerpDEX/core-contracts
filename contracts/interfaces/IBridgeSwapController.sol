pragma solidity 0.8.20;

interface IBridgeSwapController {

    struct BridgeSwapData {
        uint256 minAmountOut;
        address router;
        address receiver;
        bytes swapData;

        bytes permitData;
        uint256 deadline;
        uint256 amountPermit;
    }

    struct SwapBridgeData {
        uint256 swapAmount;
        bytes permitData;
        uint256 deadline;

        uint256 minSwapAmountOut;
        address router;
        bytes swapData;

        uint32 bridgeDstEid;
        uint256 minBridgeAmountOut;
        bytes bridgeExtraOptions;
    }

    // ========== EVENTS =========
    event RouterSet(address indexed, bool iswhitelist);
    event ExecutorSet(address indexed, bool isAdd);
    event Bridged(address indexed user, uint256 amountLD, uint256 timestamp);
    event SendBridgedToken(address indexed user, uint256 amountLD, uint256 timestamp);
    event DepositedToHyperLiquid(address indexed user, uint256 amount, uint256 timestamp);
    event SubmitBridge(address indexed toUser, uint256 amountBridge, uint256 timestamp);
    event FeeCollected(address indexed user, uint256 amountFee, address feeReceiver);
    event Swapped(address indexed user, address tokenOut, uint256 amountSwap, uint256 amountReceived, uint256 timestamp);
    event RequestExecuted(bytes orderData, uint256 timestamp);
    event Received(bytes32 guid, address user, address token, uint256 amount, uint256 timestamp);
    event Sent(bytes32 guid, uint32 bridgeDstEid, address user, address token, uint256 amount, uint256 feeAmount, uint256 timestamp);

    // ======= ERRORS ========
    error InvalidAmount();
    error InvalidAddress();
    error SwapSlippage();
    error Unauthorized();
    error Timeout();
    error OrderExisted();

}
