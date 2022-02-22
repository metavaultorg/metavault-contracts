// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IAggregatorV3Interface.sol";
import "../shared/interfaces/IBond.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/interfaces/ITreasury.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/interfaces/IStakingHelper.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/FixedPoint.sol";


library Babylonian {

    function sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;

        uint256 xx = x;
        uint256 r = 1;
        if (xx >= 0x100000000000000000000000000000000) {
            xx >>= 128;
            r <<= 64;
        }
        if (xx >= 0x10000000000000000) {
            xx >>= 64;
            r <<= 32;
        }
        if (xx >= 0x100000000) {
            xx >>= 32;
            r <<= 16;
        }
        if (xx >= 0x10000) {
            xx >>= 16;
            r <<= 8;
        }
        if (xx >= 0x100) {
            xx >>= 8;
            r <<= 4;
        }
        if (xx >= 0x10) {
            xx >>= 4;
            r <<= 2;
        }
        if (xx >= 0x8) {
            r <<= 1;
        }
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1;
        r = (r + x / r) >> 1; // Seven iterations should be enough
        uint256 r1 = x / r;
        return (r < r1 ? r : r1);
    }
}

library BitMath {

    function mostSignificantBit(uint256 x) internal pure returns (uint8 r) {
        require(x > 0, "BitMath::mostSignificantBit: zero");

        if (x >= 0x100000000000000000000000000000000) {
            x >>= 128;
            r += 128;
        }
        if (x >= 0x10000000000000000) {
            x >>= 64;
            r += 64;
        }
        if (x >= 0x100000000) {
            x >>= 32;
            r += 32;
        }
        if (x >= 0x10000) {
            x >>= 16;
            r += 16;
        }
        if (x >= 0x100) {
            x >>= 8;
            r += 8;
        }
        if (x >= 0x10) {
            x >>= 4;
            r += 4;
        }
        if (x >= 0x4) {
            x >>= 2;
            r += 2;
        }
        if (x >= 0x2) r += 1;
    }
}


interface IUniswapV2ERC20 {
    function totalSupply() external view returns (uint);
}

interface IUniswapV2Pair is IUniswapV2ERC20 {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns ( address );
    function token1() external view returns ( address );
}

interface IBondCalculator {
  function valuation( address pair_, uint amount_ ) external view returns ( uint _value );
}

contract BondCalculator is IBondCalculator {

    using FixedPoint for *;
    using SafeMath for uint;
    using SafeMath for uint112;

    address public immutable MVD;

    constructor( address _MVD ) {
        require( _MVD != address(0) );
        MVD = _MVD;
    }

    function getKValue( address _pair ) public view returns( uint k_ ) {
        uint token0 = IERC20( IUniswapV2Pair( _pair ).token0() ).decimals();
        uint token1 = IERC20( IUniswapV2Pair( _pair ).token1() ).decimals();
        uint decimals = token0.add( token1 );
        uint pair = IERC20( _pair ).decimals();
        (uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();
        if(decimals>=pair)
            k_ = reserve0.mul(reserve1).div( 10 ** decimals.sub(pair) );
        else
            k_ = reserve0.mul(reserve1).mul( 10 ** pair.sub(decimals) );
    }

    function getTotalValue( address _pair ) public view returns ( uint _value ) {
        _value = getKValue( _pair ).sqrrt().mul(2);
    }

    function valuation( address _pair, uint amount_ ) external view override returns ( uint _value ) {
        uint totalValue = getTotalValue( _pair );
        uint totalSupply = IUniswapV2Pair( _pair ).totalSupply();

        _value = totalValue.mul( FixedPoint.fraction( amount_, totalSupply ).decode112with18() ).div( 1e18 );
    }

    function markdown( address _pair ) external view returns ( uint ) {
        ( uint reserve0, uint reserve1, ) = IUniswapV2Pair( _pair ).getReserves();

        uint reserve;
        if ( IUniswapV2Pair( _pair ).token0() == MVD ) {
            reserve = reserve1;
        } else {
            reserve = reserve0;
        }
        return reserve.mul( 2 * ( 10 ** IERC20( MVD ).decimals() ) ).div( getTotalValue( _pair ) );
    }
}
