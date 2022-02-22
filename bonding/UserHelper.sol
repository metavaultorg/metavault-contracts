// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IBond.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";

contract UserHelper is MetaVaultAC {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    address[] public bonds;
    mapping(address => uint256) public bondMap; //store sequence of bonds,sequence=index+1

    address public immutable staking;
    address public immutable MVD;

    constructor(
        address _staking,
        address _MVD,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_staking != address(0));
        staking = _staking;
        require(_MVD != address(0));
        MVD = _MVD;
    }

    function stake(uint256 _amount) external {
        IERC20(MVD).transferFrom(msg.sender, address(this), _amount);
        IERC20(MVD).approve(staking, _amount);
        IStaking(staking).stake(_amount, msg.sender);
        IStaking(staking).claim(msg.sender);
    }

    function redeemAll(bool _stake) external {
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i] != address(0)) {
                if (IBond(bonds[i]).pendingPayoutFor(msg.sender) > 0) {
                    IBond(bonds[i]).redeem(msg.sender, _stake);
                }
            }
        }
    }

    function deposit(
        address _bond,
        uint256 _amount,
        uint256 _maxPrice
    ) external returns (uint256) {
        require(bondMap[_bond] != 0, "bond not registered");
        IERC20 principle = IERC20(IBond(_bond).principle());
        IERC20(principle).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(principle).approve(_bond, _amount);
        return IBond(_bond).deposit(_amount, _maxPrice, msg.sender);
    }

    function redeem(address _bond, bool _stake) external {
        require(bondMap[_bond] != 0, "bond not registered");
        if (IBond(_bond).pendingPayoutFor(msg.sender) > 0) {
            IBond(_bond).redeem(msg.sender, _stake);
        }
    }

    function addBondContract(address _bond) external onlyPolicy {
        require(_bond != address(0));
        require(bondMap[_bond] == 0, "already added");
        bonds.push(_bond);
        bondMap[_bond] = bonds.length;
    }

    function removeBondContract(address _bond, uint256 _sequence) external onlyPolicy {
        require(_sequence > 0, "invalid sequence");
        require(bondMap[_bond] != 0, "bond not registered");
        uint256 index = _sequence.sub(1);
        bonds[index] = address(0);
        delete bondMap[_bond];
    }
}
