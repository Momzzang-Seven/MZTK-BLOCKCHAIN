// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SimpleWallet {
    using SafeERC20 for IERC20;

    mapping(address => uint256) private _ethBalances;
    mapping(address => mapping(address => uint256)) private _erc20Balances;

    receive() external payable {
        depositEth();
    }

    function depositEth() public payable {
        _ethBalances[msg.sender] += msg.value;
    }

    function withdrawEth(uint256 amount) public {
        require(_ethBalances[msg.sender] >= amount, "Insufficient ETH balance");
        _ethBalances[msg.sender] -= amount;
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "Failed to send Ether");
    }

    function getEthBalance() public view returns (uint256) {
        return _ethBalances[msg.sender];
    }

    function depositErc20(address tokenAddress, uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");
        _erc20Balances[msg.sender][tokenAddress] += amount;

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawErc20(address tokenAddress, uint256 amount) public {
        require(_erc20Balances[msg.sender][tokenAddress] >= amount, "Insufficient token balance");
        _erc20Balances[msg.sender][tokenAddress] -= amount;

        IERC20(tokenAddress).safeTransfer(msg.sender, amount);
    }

    function getErc20Balance(address tokenAddress) public view returns (uint256) {
        return _erc20Balances[msg.sender][tokenAddress];
    }
}
