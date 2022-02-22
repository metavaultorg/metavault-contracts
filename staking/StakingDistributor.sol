// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/interfaces/ITreasury.sol";
import "../shared/interfaces/IERC20.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";

interface IMvdCircSupply{

    function getCirculatingSupply() external view returns (uint256);

    function getNonCirculatingMVD() external view returns (uint256);
}

contract StakingDistributor is MetaVaultAC {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ====== VARIABLES ====== */

    address public immutable MVD;
    address public immutable treasury;
    address public mvdCircSupply;

    uint256 public immutable epochLength;
    uint256 public nextEpochBlock;

    mapping(uint256 => Adjust) public adjustments;

    /* ====== STRUCTS ====== */

    struct Info {
        uint256 rate; // in ten-thousandths ( 5000 = 0.5% )
        address recipient;
    }
    Info[] public info;

    struct Adjust {
        bool add;
        uint256 rate;
        uint256 target;
    }

    /* ====== CONSTRUCTOR ====== */

    constructor(
        address _treasury,
        address _mvd,
        uint256 _epochLength,
        uint256 _nextEpochBlock,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_treasury != address(0));
        treasury = _treasury;
        require(_mvd != address(0));
        MVD = _mvd;
        epochLength = _epochLength;
        nextEpochBlock = _nextEpochBlock;
    }

    /* ====== PUBLIC FUNCTIONS ====== */

    /**
        @notice send epoch reward to staking contract
     */
    function distribute() external returns (bool) {
        if (nextEpochBlock <= block.number) {
            nextEpochBlock = nextEpochBlock.add(epochLength); // set next epoch block

            // distribute rewards to each recipient
            for (uint256 i = 0; i < info.length; i++) {
                if (info[i].rate > 0) {
                    ITreasury(treasury).mintRewards(info[i].recipient, nextRewardAt(info[i].rate)); // mint and send from treasury
                    adjust(i); // check for adjustment
                }
            }
            return true;
        } else {
            return false;
        }
    }

    /* ====== INTERNAL FUNCTIONS ====== */

    /**
        @notice increment reward rate for collector
     */
    function adjust(uint256 _index) internal {
        Adjust memory adjustment = adjustments[_index];
        if (adjustment.rate != 0) {
            if (adjustment.add) {
                // if rate should increase
                info[_index].rate = info[_index].rate.add(adjustment.rate); // raise rate
                if (info[_index].rate >= adjustment.target) {
                    // if target met
                    adjustments[_index].rate = 0; // turn off adjustment
                }
            } else {
                // if rate should decrease
                info[_index].rate = info[_index].rate.sub(adjustment.rate); // lower rate
                if (info[_index].rate <= adjustment.target) {
                    // if target met
                    adjustments[_index].rate = 0; // turn off adjustment
                }
            }
        }
    }

    /* ====== VIEW FUNCTIONS ====== */

    /**
        @notice view function for next reward at given rate
        @param _rate uint
        @return uint
     */
    function nextRewardAt(uint256 _rate) public view returns (uint256) {
        if(mvdCircSupply == address(0)) {
            return IERC20(MVD).totalSupply().mul(_rate).div(1000000);
        }
        return IMvdCircSupply(mvdCircSupply).getCirculatingSupply().mul(_rate).div(1000000);
    }

    /**
        @notice view function for next reward for specified address
        @param _recipient address
        @return uint
     */
    function nextRewardFor(address _recipient) public view returns (uint256) {
        uint256 reward;
        for (uint256 i = 0; i < info.length; i++) {
            if (info[i].recipient == _recipient) {
                reward = nextRewardAt(info[i].rate);
            }
        }
        return reward;
    }

    /* ====== POLICY FUNCTIONS ====== */

    /**
        @notice add Mvd Circ Supply Contract Address
        @param _mvdCircSupplyAddress address
     */
    function setMvdCircSupply(address _mvdCircSupplyAddress) external onlyPolicy {
        mvdCircSupply = _mvdCircSupplyAddress;
    }

    /**
        @notice adds recipient for distributions
        @param _recipient address
        @param _rewardRate uint
     */
    function addRecipient(address _recipient, uint256 _rewardRate) external onlyPolicy {
        require(_recipient != address(0));
        info.push(Info({recipient: _recipient, rate: _rewardRate}));
    }

    /**
        @notice removes recipient for distributions
        @param _index uint
        @param _recipient address
     */
    function removeRecipient(uint256 _index, address _recipient) external onlyPolicy {
        require(_recipient == info[_index].recipient);
        info[_index].recipient = address(0);
        info[_index].rate = 0;
    }

    /**
        @notice set adjustment info for a collector's reward rate
        @param _index uint
        @param _add bool
        @param _rate uint
        @param _target uint
     */
    function setAdjustment(
        uint256 _index,
        bool _add,
        uint256 _rate,
        uint256 _target
    ) external onlyPolicy {
        adjustments[_index] = Adjust({add: _add, rate: _rate, target: _target});
    }
}
