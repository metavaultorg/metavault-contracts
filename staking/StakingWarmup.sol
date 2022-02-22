// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IERC20.sol";


contract StakingWarmup {

    address public immutable staking;
    address public immutable sMVD;

    constructor ( address _staking, address _sMVD ) {
        require( _staking != address(0) );
        staking = _staking;
        require( _sMVD != address(0) );
        sMVD = _sMVD;
    }

    function retrieve( address _staker, uint _amount ) external {
        require( msg.sender == staking );
        IERC20( sMVD ).transfer( _staker, _amount );
    }
}