// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IYieldDirector {
    function deposit(uint256 amount_, address recipient_) external;

    function withdraw(uint256 amount_, address recipient_) external;

    function withdrawAll() external;

    function depositsTo(address donor_, address recipient_) external view returns (uint256);

    function getAllDeposits(address donor_) external view returns (address[] memory, uint256[] memory);

    function totalDeposits(address donor_) external view returns (uint256);

    function donatedTo(address donor_, address recipient_) external view returns (uint256);

    function totalDonated(address donor_) external view returns (uint256);

    function redeem() external;

    function redeemableBalance(address recipient_) external view returns (uint256);
}
