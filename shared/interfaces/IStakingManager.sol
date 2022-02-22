// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IStakingManager {
    function stake(uint256 _amount, address _recipient) external returns (bool);

    function claim(address _recipient) external;

    function warmupPeriod() external view returns (uint256);
}
