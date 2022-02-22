// SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import "../shared/interfaces/IERC20.sol";
import "../shared/interfaces/IStaking.sol";

contract StakingHelper {
    address public immutable staking;
    address public immutable MVD;

    constructor(address _staking, address _MVD) {
        require(_staking != address(0));
        staking = _staking;
        require(_MVD != address(0));
        MVD = _MVD;
    }

    function stake(uint256 _amount, address _recipient) external {
        IERC20(MVD).transferFrom(msg.sender, address(this), _amount);
        IERC20(MVD).approve(staking, _amount);
        IStaking(staking).stake(_amount, _recipient);
        IStaking(staking).claim(_recipient);
    }
}
