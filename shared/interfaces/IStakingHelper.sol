// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IStakingHelper {
    function stake(uint256 _amount, address _recipient) external;
}
