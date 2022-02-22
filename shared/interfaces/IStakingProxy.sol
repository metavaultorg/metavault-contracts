// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IStakingProxy {
    function stake(uint256 _amount, address _recipient) external returns (bool);

    function claim(address _recipient) external;
}
