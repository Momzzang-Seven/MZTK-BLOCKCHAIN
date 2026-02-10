// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {SimpleWallet} from "../src/SimpleWallet.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockToken is ERC20 {
    constructor() ERC20("MockToken", "MTK") {
        _mint(msg.sender, 1000 ether);
    }
}

contract SimpleWalletTest is Test {
    using SafeERC20 for MockToken;
    SimpleWallet public wallet;
    MockToken public token;
    
    address public user = address(0xABCD);

    function setUp() public {
        wallet = new SimpleWallet();
        token = new MockToken();
        
        vm.deal(user, 10 ether);
        token.safeTransfer(user, 100 ether);
    }


    function test_DepositEth() public {
        vm.startPrank(user);
        wallet.depositEth{value: 1 ether}();

        assertEq(wallet.getEthBalance(), 1 ether);
        assertEq(address(wallet).balance, 1 ether);

        vm.stopPrank();
    }

    function test_WithdrawEth() public {
        vm.startPrank(user);
        wallet.depositEth{value: 2 ether}();
        
        uint256 beforeBalance = user.balance;
        wallet.withdrawEth(1 ether);
        
        assertEq(wallet.getEthBalance(), 1 ether);
        assertEq(user.balance, beforeBalance + 1 ether);
        vm.stopPrank();
    }

    function test_DepositErc20() public {
        vm.startPrank(user);
        uint256 depositAmount = 50 ether;

        token.approve(address(wallet), depositAmount);
        wallet.depositErc20(address(token), depositAmount);

        assertEq(wallet.getErc20Balance(address(token)), depositAmount);
        assertEq(token.balanceOf(address(wallet)), depositAmount);
        vm.stopPrank();
    }

    function test_WithdrawErc20() public {
        vm.startPrank(user);
        uint256 amount = 50 ether;

        token.approve(address(wallet), amount);
        wallet.depositErc20(address(token), amount);

        wallet.withdrawErc20(address(token), 20 ether);
        
        assertEq(wallet.getErc20Balance(address(token)), 30 ether);
        assertEq(token.balanceOf(user), 70 ether); 
        vm.stopPrank();
    }

    function test_RevertOnInsufficientEth() public {
        vm.prank(user);
        vm.expectRevert("Insufficient ETH balance");
        wallet.withdrawEth(1 ether);
    }
}