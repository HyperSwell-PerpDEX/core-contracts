pragma solidity >=0.8.0;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUSDCPermit} from "../interfaces/IUSDCPermit.sol";

/**
 * wrap SafeTransferLib to retain oz SafeERC20 signature
 */
library SafeERC20 {
    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        SafeTransferLib.safeTransferFrom(address(token), from, to, amount);
    }

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        SafeTransferLib.safeTransfer(address(token), to, amount);
    }

    function safeIncreaseAllowance(IERC20 token, address spender, uint256 amount) internal {
        uint256 allowance = token.allowance(msg.sender, spender) + amount;
        SafeTransferLib.safeApprove(address(token), spender, allowance);
    }

    function safePermit(
        IERC20 token,
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        bytes memory signature
    ) internal {
        IUSDCPermit tokenPermit = IUSDCPermit(address(token));
        try tokenPermit.permit(owner, spender, value, deadline, signature) {} catch {
            if (tokenPermit.allowance(owner, spender) < value) {
                revert("SafeERC20: permit did not succeed");
            }
        }
    }
}
