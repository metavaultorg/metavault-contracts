// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

interface IBond {
    function initializeBondTerms(
        uint256 _controlVariable,
        uint256 _vestingTerm,
        uint256 _minimumPrice,
        uint256 _maxPayout,
        uint256 _fee,
        uint256 _maxDebt,
        uint256 _initialDebt
    ) external;

    function totalDebt() external view returns (uint256);

    function isLiquidityBond() external view returns (bool);

    function bondPrice() external view returns (uint256);

    function bondPriceInUSD() external view returns (uint256 price_);

    function redeem(address _recipient, bool _stake) external returns (uint256);

    function pendingPayoutFor(address _depositor) external view returns (uint256 pendingPayout_);

    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external returns (uint256);

    function principle() external view returns (address);

    function terms()
        external
        view
        returns (
            uint256 controlVariable, // scaling variable for price
            uint256 vestingTerm, // in blocks
            uint256 minimumPrice, // vs principle value
            uint256 maxPayout, // in thousandths of a %. i.e. 500 = 0.5%
            uint256 fee, // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
            uint256 maxDebt // 9 decimal debt ratio, max % total supply created as debt
        );
}
