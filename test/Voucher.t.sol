// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {Test} from "forge-std/Test.sol";
import {Voucher} from "../src/Voucher.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MCK") { _mint(msg.sender, 1000 ether); }
}

contract VoucherTest is Test {
    using SafeERC20 for MockToken;
    Voucher public voucher;
    MockToken public token;
    
    address public admin = address(1);
    address public user = address(2);
    bytes32 public secretCode = keccak256("MZTK_DISCOUNT_2026");

    function setUp() public {
        vm.startPrank(admin);
        token = new MockToken();
        voucher = new Voucher(address(token));
        
        token.safeTransfer(address(voucher), 500 ether);
        vm.stopPrank();
    }

    function test_IssueAndRedeem() public {
        uint256 reward = 10 ether;

        vm.prank(admin);
        voucher.issueVoucher(secretCode, reward);

        vm.prank(user);
        voucher.redeemVoucher(secretCode);

        assertEq(token.balanceOf(user), reward);
        assertTrue(voucher.usedVouchers(secretCode));
    }

    function test_Fail_DoubleRedeem() public {
        vm.prank(admin);
        voucher.issueVoucher(secretCode, 10 ether);

        vm.startPrank(user);
        voucher.redeemVoucher(secretCode);
        
        vm.expectRevert("Voucher already used");
        voucher.redeemVoucher(secretCode);
        vm.stopPrank();
    }

    function test_Fail_UnauthorizedIssue() public {
        vm.prank(user);
        vm.expectRevert();
        voucher.issueVoucher(secretCode, 10 ether);
    }
}