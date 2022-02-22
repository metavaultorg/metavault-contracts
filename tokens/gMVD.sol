// SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/Address.sol";

import "../shared/types/ERC20Permit.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IsMVD.sol";

contract gMVD is ERC20 {
    using SafeERC20 for ERC20;
    using Address for address;
    using SafeMath for uint256;

    address public immutable sMVD;

    constructor(address _sMVD) ERC20("Governance Metavault", "gMVD", 18) {
        require(_sMVD != address(0));
        sMVD = _sMVD;
    }

    /**
        @notice wrap sMVD
        @param _amount uint
        @return uint
     */
    function wrap(uint256 _amount) external returns (uint256) {
        IERC20(sMVD).transferFrom(msg.sender, address(this), _amount);

        uint256 value = sMVDTogMVD(_amount);
        _mint(msg.sender, value);
        return value;
    }

    /**
        @notice unwrap sMVD
        @param _amount uint
        @return uint
     */
    function unwrap(uint256 _amount) external returns (uint256) {
        _burn(msg.sender, _amount);

        uint256 value = gMVDTosMVD(_amount);
        IERC20(sMVD).transfer(msg.sender, value);
        return value;
    }

    /**
        @notice converts gMVD amount to sMVD
        @param _amount uint
        @return uint
     */
    function gMVDTosMVD(uint256 _amount) public view returns (uint256) {
        return _amount.mul(IsMVD(sMVD).index()).div(10**decimals());
    }

    /**
        @notice converts sMVD amount to gMVD
        @param _amount uint
        @return uint
     */
    function sMVDTogMVD(uint256 _amount) public view returns (uint256) {
        return _amount.mul(10**decimals()).div(IsMVD(sMVD).index());
    }
}
