// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/interfaces/IStakingProxy.sol";
import "../shared/interfaces/IERC20.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";

contract StakingManager is MetaVaultAC {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    address public immutable MVD;
    address public immutable staking;

    uint256 public epoch = 0;

    uint256 public warmupPeriod = 0;
    address[] public proxies;

    constructor(
        address _mvd,
        address _staking,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_mvd != address(0));
        MVD = _mvd;
        require(_staking != address(0));
        staking = _staking;
    }

    function addProxy(address _proxy) external onlyPolicy {
        require(_proxy != address(0));

        for (uint256 i = 0; i < proxies.length; i++) {
            if (proxies[i] == _proxy) {
                return;
            }
        }

        proxies.push(_proxy);
    }

    function removeProxy(address _proxy) external onlyPolicy returns (bool) {
        require(_proxy != address(0));

        for (uint256 i = 0; i < proxies.length; i++) {
            if (proxies[i] == _proxy) {
                require(proxies.length - 1 >= warmupPeriod, "Not enough proxies to support specified period.");
                for (uint256 j = i; j < proxies.length - 1; j++) {
                    proxies[j] = proxies[j + 1];
                }

                proxies.pop();
                return true;
            }
        }

        return false;
    }

    function setWarmupPeriod(uint256 period) external onlyPolicy {
        require(proxies.length >= period, "Not enough proxies to support specified period.");

        warmupPeriod = period;
    }

    function stake(uint256 _amount, address _recipient) external returns (bool) {
        require(proxies.length > 0, "No proxies defined.");
        require(_recipient != address(0));
        require(_amount != 0); // why would anyone need to stake 0 MVD?
        IStaking(staking).rebase();
        uint256 stakingEpoch = getStakingEpoch();
        if (epoch < stakingEpoch) {
            epoch = stakingEpoch; // set next epoch block

            claim(_recipient); // claim any expired warmups before rolling to the next epoch
        }

        address targetProxy = proxies[warmupPeriod == 0 ? 0 : epoch % warmupPeriod];
        require(targetProxy != address(0));

        IERC20(MVD).safeTransferFrom(msg.sender, targetProxy, _amount);

        return IStakingProxy(targetProxy).stake(_amount, _recipient);
    }

    function claim(address _recipient) public {
        require(proxies.length > 0, "No proxies defined.");
        require(_recipient != address(0));

        for (uint256 i = 0; i < proxies.length; i++) {
            require(proxies[i] != address(0));

            IStakingProxy(proxies[i]).claim(_recipient);
        }
    }

    function getStakingEpoch() public view returns (uint256 stakingEpoch) {
        (, stakingEpoch, , ) = IStaking(staking).epoch();
    }
}
