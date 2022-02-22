// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IBond.sol";
import "../shared/types/MetaVaultAC.sol";

contract RedeemHelper is MetaVaultAC {
    address[] public bonds;

    constructor(address _authority) MetaVaultAC(IMetaVaultAuthority(_authority)) {}

    function redeemAll(address _recipient, bool _stake) external {
        for (uint256 i = 0; i < bonds.length; i++) {
            if (bonds[i] != address(0)) {
                if (IBond(bonds[i]).pendingPayoutFor(_recipient) > 0) {
                    IBond(bonds[i]).redeem(_recipient, _stake);
                }
            }
        }
    }

    function addBondContract(address _bond) external onlyPolicy {
        require(_bond != address(0));
        bonds.push(_bond);
    }

    function removeBondContract(uint256 _index) external onlyPolicy {
        bonds[_index] = address(0);
    }
}
