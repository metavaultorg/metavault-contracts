// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IBackingCalculator {
    //decimals for backing is 4
    function backing() external view returns (uint256 _lpBacking, uint256 _treasuryBacking);

    //decimals for backing is 4
    function lpBacking() external view returns (uint256 _lpBacking);

    //decimals for backing is 4
    function treasuryBacking() external view returns (uint256 _treasuryBacking);

    //decimals for backing is 4
    function backing_full()
        external
        view
        returns (
            uint256 _lpBacking,
            uint256 _treasuryBacking,
            uint256 _totalStableReserve,
            uint256 _totalMvdReserve,
            uint256 _totalStableBal,
            uint256 _cirulatingMvd
        );
}
