// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IMvdCirculatingSupply {
    function getCirculatingSupply() external view returns (uint256);
}
