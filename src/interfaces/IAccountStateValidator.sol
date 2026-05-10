// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

bytes4 constant ACCOUNT_STATE_VALIDATION_SUCCESS = 0x00000000;

interface IAccountStateValidator {
    function validateAccountState(address account, address implementation) external view returns (bytes4);
}
