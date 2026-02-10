// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {MyERC20} from "../src/MyERC20.sol";

contract MyERC20Test is Test {
    MyERC20 public token;
    address public user = address(0x1);
    uint256 public initialSupply = 1000 ether;

    function setUp() public {
        token = new MyERC20("MZTK Token", "MZTK", initialSupply);
    }

    function testInitialSupply() public view {
        assertEq(token.balanceOf(address(this)), initialSupply);
    }

    function testMint() public {
        uint256 mintAmount = 500 ether;
        token.mint(user, mintAmount);
        assertEq(token.balanceOf(user), mintAmount);
    }

    function testBurn() public {
        uint256 burnAmount = 200 ether;
        token.mint(user, burnAmount);
        token.burn(user, burnAmount);
        assertEq(token.balanceOf(user), 0);
    }

    function testPublicMint() public {
        uint256 mintAmount = 100 ether;
        
        vm.prank(user);
        token.mint(user, mintAmount);
        
        assertEq(token.balanceOf(user), mintAmount);
    }
}