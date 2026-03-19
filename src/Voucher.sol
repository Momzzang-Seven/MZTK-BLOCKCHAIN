// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Voucher is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable REWARD_TOKEN;
    mapping(bytes32 => uint256) public voucherAmounts;
    mapping(bytes32 => bool) public usedVouchers;

    event VoucherIssued(bytes32 indexed code, uint256 amount);
    event VoucherRedeemed(address indexed user, bytes32 indexed code, uint256 amount);

    constructor(address _token) Ownable(msg.sender) {
        REWARD_TOKEN = IERC20(_token);
    }

    function issueVoucher(bytes32 code, uint256 amount) external onlyOwner {
        require(code != bytes32(0), "Invalid code");
        require(voucherAmounts[code] == 0, "Voucher already issued");
        require(amount > 0, "Amount must be greater than 0");

        voucherAmounts[code] = amount;
        emit VoucherIssued(code, amount);
    }

    function redeemVoucher(bytes32 code) external {
        uint256 amount = voucherAmounts[code];

        require(amount > 0, "Invalid voucher code");
        require(!usedVouchers[code], "Voucher already used");

        usedVouchers[code] = true;

        REWARD_TOKEN.safeTransfer(msg.sender, amount);

        emit VoucherRedeemed(msg.sender, code, amount);
    }
}
