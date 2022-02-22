// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/interfaces/IStakingManager.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/interfaces/IERC20.sol";
import "../shared/libraries/SafeERC20.sol";


contract StakingProxy {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public immutable MVD;
    address public immutable sMVD;
    address public immutable manager;
    address public immutable staking;
    uint256 public lastStakedEpoch;

    struct Claim {
        uint256 deposit;
        uint256 gons;
        uint256 expiry;
    }
    mapping(address => Claim) public claims;

    constructor(
        address _mvd, // MVD Token contract address
        address _smvd, // sMVD Token contract address
        address _manager, // Staking Manager contract address
        address _staking
    ) {
        require(_mvd != address(0));
        require(_smvd != address(0));
        require(_manager != address(0));
        require(_staking != address(0));

        MVD = _mvd;
        sMVD = _smvd;
        manager = _manager;
        staking = _staking;
    }

    function stake(uint256 _amount, address _recipient) external returns (bool) {
        require(msg.sender == manager); // only allow calls from the StakingManager
        require(_recipient != address(0));
        require(_amount != 0); // why would anyone need to stake 0 MVD?
        Claim memory claimInfo = claims[_recipient];

        uint256 stakingEpoch = getStakingEpoch();
        if (claimInfo.expiry <= stakingEpoch) {
            claim(_recipient);
        }

        lastStakedEpoch = stakingEpoch;
        claims[_recipient] = Claim({
            deposit: claimInfo.deposit.add(_amount),
            gons: claimInfo.gons.add(IsMVD(sMVD).gonsForBalance(_amount)),
            expiry: lastStakedEpoch.add(IStakingManager(staking).warmupPeriod())
        });

        IERC20(MVD).approve(staking, _amount);
        return IStaking(staking).stake(_amount, address(this));
    }

    function claim(address _recipient) public {
        require(msg.sender == manager); // only allow calls from the StakingManager
        require(_recipient != address(0));

        if (getStakingEpoch() >= lastStakedEpoch + IStakingManager(staking).warmupPeriod()) {
            IStaking(staking).claim(address(this));
        }
        Claim memory claimInfo = claims[_recipient];
        if (claimInfo.gons == 0 || claimInfo.expiry > getStakingEpoch()) {
            return;
        }

        delete claims[_recipient];
        IERC20(sMVD).transfer(_recipient, IsMVD(sMVD).balanceForGons(claimInfo.gons));
    }

    function getStakingEpoch() public view returns (uint256 stakingEpoch) {
        (, stakingEpoch, , ) = IStaking(staking).epoch();
    }
}
