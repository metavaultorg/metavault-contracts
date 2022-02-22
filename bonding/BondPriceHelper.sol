// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IBond.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";

contract BondPriceHelper is MetaVaultAC {
    using SafeMath for uint256;

    mapping(address => bool) public executors;
    mapping(address => bool) public bonds;

    constructor(address _authority) MetaVaultAC(IMetaVaultAuthority(_authority)) {}

    function addExecutor(address executor) external onlyGovernor {
        executors[executor] = true;
    }

    function removeExecutor(address executor) external onlyGovernor {
        delete executors[executor];
    }

    function addBond(address bond) external onlyGovernor {
        //IBond(bond).bondPrice();
        IBond(bond).terms();
        IBond(bond).isLiquidityBond();
        bonds[bond] = true;
    }

    function removeBond(address bond) external onlyGovernor {
        delete bonds[bond];
    }

    function recal(address bond, uint256 percent) internal view returns (uint256) {
        if (IBond(bond).isLiquidityBond()) return percent;
        else {
            uint256 price = IBond(bond).bondPrice();
            return price.mul(percent).sub(1000000).div(price.sub(100));
        }
    }

    function viewPriceAdjust(address bond, uint256 percent)
        external
        view
        returns (
            uint256 _controlVar,
            uint256 _oldControlVar,
            uint256 _minPrice,
            uint256 _oldMinPrice,
            uint256 _price
        )
    {
        uint256 price = IBond(bond).bondPrice();
        (uint256 controlVariable, , uint256 minimumPrice, , , ) = IBond(bond).terms();
        if (minimumPrice == 0) {
            return (controlVariable.mul(recal(bond, percent)).div(10000), controlVariable, minimumPrice, minimumPrice, price);
        } else return (controlVariable, controlVariable, minimumPrice.mul(percent).div(10000), minimumPrice, price);
    }

    function adjustPrice(address bond, uint256 percent) external {
        if (percent == 0) return;
        require(percent > 8000 && percent < 12000, "price adjustment can't be more than 20%");
        require(executors[msg.sender] == true, "access deny for price adjustment");
        (uint256 controlVariable, uint256 vestingTerm, uint256 minimumPrice, uint256 maxPayout, uint256 fee, uint256 maxDebt) = IBond(bond).terms();
        if (minimumPrice == 0) {
            IBond(bond).initializeBondTerms(controlVariable.mul(recal(bond, percent)).div(10000), vestingTerm, minimumPrice, maxPayout, fee, maxDebt, IBond(bond).totalDebt());
        } else IBond(bond).initializeBondTerms(controlVariable, vestingTerm, minimumPrice.mul(percent).div(10000), maxPayout, fee, maxDebt, IBond(bond).totalDebt());
    }

}
