// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IBond.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";

interface IPriceHelperV2 {
    function adjustPrice(address bond, uint256 percent) external;
}

interface IUniV2Pair {
    function getReserves()
        external
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        );

    function token0() external view returns (address);

    function token1() external view returns (address);
}

contract BondPriceStrategy is MetaVaultAC {
    using SafeMath for uint256;

    IPriceHelperV2 public helper;
    address public mvDdai;
    IsMVD public sMVD;
    IStaking public staking;

    uint256 public additionalLp11MinDiscount; //100 = 1%
    uint256 public additionalLp11MaxDiscount;

    uint256 public min44Discount;
    uint256 public max44Discount;

    uint256 public additionalAsset11MinDiscount;
    uint256 public additionalAsset11MaxDiscount;

    uint256 public adjustmentBlockGap;

    mapping(address => bool) public executors;

    mapping(address => TYPES) public bondTypes;
    mapping(address => uint256) public usdPriceDecimals;
    mapping(address => uint256) public lastAdjustBlockNumbers;
    address[] public bonds;
    mapping(address => uint256) public perBondDiscounts;

    address public mvd;

    constructor(address _authority) MetaVaultAC(IMetaVaultAuthority(_authority)) {}

    function setLp11(uint256 min, uint256 max) external onlyGovernor {
        require(min <= 500 && max <= 1000, "additional disccount can't be more than 5%-10%");
        additionalLp11MinDiscount = min;
        additionalLp11MaxDiscount = max;
    }

    function setAsset11(uint256 min, uint256 max) external onlyGovernor {
        require(min <= 500 && max <= 1000, "additional disccount can't be more than 5%-10%");
        additionalAsset11MinDiscount = min;
        additionalAsset11MaxDiscount = max;
    }

    function setAll44(uint256 min, uint256 max) external onlyGovernor {
        require(min <= 500 && max <= 1000, "additional disccount can't be more than 5%-10%");
        min44Discount = min;
        max44Discount = max;
    }

    function setHelper(address _helper) external onlyGovernor {
        require(_helper != address(0));
        helper = IPriceHelperV2(_helper);
    }

    function setMvdDai(address _mvdDai) external onlyGovernor {
        require(_mvdDai != address(0));
        mvDdai = _mvdDai;
    }

    function setSMVD(address _sMVD) external onlyGovernor {
        require(_sMVD != address(0));
        sMVD = IsMVD(_sMVD);
    }

    function setStaking(address _staking) external onlyGovernor {
        require(_staking != address(0));
        staking = IStaking(_staking);
    }

    function setMVD(address _mvd) external onlyGovernor {
        require(_mvd != address(0));
        mvd = _mvd;
    }

    function setAdjustmentBlockGap(uint256 _adjustmentBlockGap) external onlyGovernor {
        require(_adjustmentBlockGap >= 600 && _adjustmentBlockGap <= 28800);
        adjustmentBlockGap = _adjustmentBlockGap;
    }

    function addExecutor(address executor) external onlyGovernor {
        executors[executor] = true;
    }

    function removeExecutor(address executor) external onlyGovernor {
        delete executors[executor];
    }

    enum TYPES {
        NOTYPE,
        ASSET11,
        ASSET44,
        LP11,
        LP44
    }

    function addBond(
        address bond,
        TYPES bondType,
        uint256 usdPriceDecimal
    ) external onlyGovernor {
        require(bondType == TYPES.ASSET11 || bondType == TYPES.ASSET44 || bondType == TYPES.LP11 || bondType == TYPES.LP44, "incorrect bond type");
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i] == bond) return;
        }
        bonds.push(bond);
        bondTypes[bond] = bondType;
        usdPriceDecimals[bond] = usdPriceDecimal;
        lastAdjustBlockNumbers[bond] = block.number;
    }

    function removeBond(address bond) external onlyGovernor {
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i] == bond) {
                bonds[i] = address(0);
                delete bondTypes[bond];
                delete usdPriceDecimals[bond];
                delete lastAdjustBlockNumbers[bond];
                delete perBondDiscounts[bond];
                return;
            }
        }
    }

    function setBondSpecificDiscount(address bond, uint256 discount) external onlyGovernor {
        require(discount <= 200, "per bond discount can't be more than 2%");
        require(bondTypes[bond] != TYPES.NOTYPE, "not a bond under strategy");
        perBondDiscounts[bond] = discount;
    }

    function runPriceStrategy() external {
        require(executors[msg.sender] == true, "not authorized to run strategy");
        uint256 mvdPrice = getPrice(mvDdai); //$220 = 22000
        uint256 roi5day = getRoiForDays(5); //2% = 200
        for (uint256 i = 0; i < bonds.length; i++) {
            address bond = bonds[i];
            if (bond != address(0) && lastAdjustBlockNumbers[bond] + adjustmentBlockGap < block.number) {
                executeStrategy(bond, mvdPrice, roi5day);
                lastAdjustBlockNumbers[bond] = block.number;
            }
        }
    }

    function runSinglePriceStrategy(uint256 i) external {
        require(executors[msg.sender] == true, "not authorized to run strategy");
        address bond = bonds[i];
        require(bond != address(0), "bond not found");
        uint256 mvdPrice = getPrice(mvDdai); //$220 = 22000
        uint256 roi5day = getRoiForDays(5); //2% = 200
        if (lastAdjustBlockNumbers[bond] + adjustmentBlockGap < block.number) {
            executeStrategy(bond, mvdPrice, roi5day);
            lastAdjustBlockNumbers[bond] = block.number;
        }
    }

    function getBondPriceUSD(address bond) public view returns (uint256) {
        return IBond(bond).bondPriceInUSD();
    }

    function getBondPrice(address bond) public view returns (uint256) {
        return getBondPriceUSD(bond).mul(100).div(10**usdPriceDecimals[bond]);
    }

    function executeStrategy(
        address bond,
        uint256 mvdPrice,
        uint256 roi5day
    ) internal {
        uint256 percent = calcPercentage(bondTypes[bond], mvdPrice, getBondPrice(bond), roi5day, perBondDiscounts[bond]);
        if (percent > 11000) helper.adjustPrice(bond, 11000);
        else if (percent < 9000) helper.adjustPrice(bond, 9000);
        else if (percent >= 10100 || percent <= 9900) helper.adjustPrice(bond, percent);
    }

    function calcPercentage(
        TYPES bondType,
        uint256 mvdPrice,
        uint256 bondPrice,
        uint256 roi5day,
        uint256 perBondDiscount
    ) public view returns (uint256) {
        uint256 upper = bondPrice;
        uint256 lower = bondPrice;
        if (bondType == TYPES.LP44 || bondType == TYPES.ASSET44) {
            upper = mvdPrice.mul(10000).div(uint256(10000).add(min44Discount).add(perBondDiscount));
            lower = mvdPrice.mul(10000).div(uint256(10000).add(max44Discount).add(perBondDiscount));
        } else if (bondType == TYPES.LP11) {
            upper = mvdPrice.mul(10000).div(uint256(10000).add(roi5day).add(additionalLp11MinDiscount).add(perBondDiscount));
            lower = mvdPrice.mul(10000).div(uint256(10000).add(roi5day).add(additionalLp11MaxDiscount).add(perBondDiscount));
        } else if (bondType == TYPES.ASSET11) {
            upper = mvdPrice.mul(10000).div(uint256(10000).add(roi5day).add(additionalAsset11MinDiscount).add(perBondDiscount));
            lower = mvdPrice.mul(10000).div(uint256(10000).add(roi5day).add(additionalAsset11MaxDiscount).add(perBondDiscount));
        }
        uint256 targetPrice = bondPrice;
        if (bondPrice > upper) targetPrice = upper;
        else if (bondPrice < lower) targetPrice = lower;
        uint256 percentage = targetPrice.mul(10000).div(bondPrice);
        return percentage;
    }

    function getRoiForDays(uint256 numberOfDays) public view returns (uint256) {
        require(numberOfDays > 0);
        uint256 circulating = sMVD.circulatingSupply();
        uint256 distribute = 0;
        (, , , distribute) = staking.epoch();
        if (distribute == 0) return 0;
        uint256 precision = 1e6;
        uint256 epochBase = distribute.mul(precision).div(circulating).add(precision);
        uint256 dayBase = epochBase.mul(epochBase).mul(epochBase).div(precision * precision);
        uint256 total = dayBase;
        for (uint256 i = 0; i < numberOfDays - 1; i++) {
            total = total.mul(dayBase).div(precision);
        }
        return total.sub(precision).div(100);
    }

    function getPrice(address _mvDdai) public view returns (uint256) {
        uint112 _reserve0 = 0;
        uint112 _reserve1 = 0;
        (_reserve0, _reserve1, ) = IUniV2Pair(_mvDdai).getReserves();
        uint256 reserve0 = uint256(_reserve0);
        uint256 reserve1 = uint256(_reserve1);
        uint256 decimals0 = uint256(IERC20(IUniV2Pair(_mvDdai).token0()).decimals());
        uint256 decimals1 = uint256(IERC20(IUniV2Pair(_mvDdai).token1()).decimals());
        if (IUniV2Pair(_mvDdai).token0() == mvd) return reserve1.mul(10**decimals0).div(reserve0).div(10**(decimals1.sub(2)));
        //$220 = 22000
        else return reserve0.mul(10**decimals1).div(reserve1).div(10**(decimals0.sub(2))); //$220 = 22000
    }
}
