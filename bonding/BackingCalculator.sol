// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IAggregatorV3Interface.sol";
import "../shared/interfaces/IMvdCirculatingSupply.sol";
import "../shared/interfaces/IBackingCalculator.sol";
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

interface IPair is IERC20 {
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

interface Investment {
    function totalValueDeployed() external view returns (uint256);
}

contract BackingCalculator is IBackingCalculator, MetaVaultAC {
    using SafeMath for uint256;

    enum STATUS {
        PENDING,
        ACTIVE,
        PASSIVE
    }

    mapping(address => STATUS) public pairs;
    mapping(uint256 => address) public pairIndice;

    mapping(address => STATUS) public tokens;
    mapping(uint256 => address) public tokenIndice;

    mapping(address => STATUS) public investments;
    mapping(uint256 => address) public investmentIndice;

    uint256 public numberOfTokens;
    uint256 public numberOfPairs;
    uint256 public numberOfInvestments;

    address public MVD;
    address public treasury;
    IMvdCirculatingSupply public mvdCirculation;

    constructor(
        address _mvd,
        address _treasury,
        address _mvdCirculatingSupply,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_mvd != address(0));
        MVD = _mvd;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_mvdCirculatingSupply != address(0));
        mvdCirculation = IMvdCirculatingSupply(_mvdCirculatingSupply);
    }

    function addPair(address _pair) external onlyGovernor {
        require(pairs[_pair] == STATUS.PENDING, "Use set status to re-activate");
        pairs[_pair] = STATUS.ACTIVE;
        pairIndice[numberOfPairs] = _pair;
        numberOfPairs++;
    }

    function addToken(address _token) external onlyGovernor {
        require(tokens[_token] == STATUS.PENDING, "Use set status to re-activate");
        tokens[_token] = STATUS.ACTIVE;
        tokenIndice[numberOfTokens] = _token;
        numberOfTokens++;
    }

    function addInvestment(address _investment) external onlyGovernor {
        require(investments[_investment] == STATUS.PENDING, "Use set status to re-activate");
        investments[_investment] = STATUS.ACTIVE;
        investmentIndice[numberOfInvestments] = _investment;
        numberOfInvestments++;
    }

    function setPairStatus(address _pair, STATUS _status) external onlyGovernor {
        require(_status != STATUS.PENDING, "Only Active or Passive");
        require(pairs[_pair] != STATUS.PENDING, "Should be added before set status");
        pairs[_pair] = _status;
    }

    function setTokenStatus(address _token, STATUS _status) external onlyGovernor {
        require(_status != STATUS.PENDING, "Only Active or Passive");
        require(tokens[_token] != STATUS.PENDING, "Should be added before set status");
        tokens[_token] = _status;
    }

    function setInvestmentStatus(address _investment, STATUS _status) external onlyGovernor {
        require(_status != STATUS.PENDING, "Only Active or Passive");
        require(investments[_investment] != STATUS.PENDING, "Should be added before set status");
        investments[_investment] = _status;
    }

    function backing() external view override returns (uint256 _lpBacking, uint256 _treasuryBacking) {
        (_lpBacking, _treasuryBacking, , , , ) = backing_full();
    }

    function lpBacking() external view override returns (uint256 _lpBacking) {
        (_lpBacking, , , , , ) = backing_full();
    }

    function treasuryBacking() external view override returns (uint256 _treasuryBacking) {
        (, _treasuryBacking, , , , ) = backing_full();
    }

    //decimals for backing is 4
    function backing_full()
        public
        view
        override
        returns (
            uint256 _lpBacking,
            uint256 _treasuryBacking,
            uint256 _totalStableReserve,
            uint256 _totalMvdReserve,
            uint256 _totalStableBal,
            uint256 _cirulatingMvd
        )
    {
        // lp
        uint256 stableReserve;
        uint256 mvdReserve;

        // Stable and MVD Reserves
        for (uint256 i = 0; i < numberOfPairs; i++) {
            if (pairs[pairIndice[i]] == STATUS.ACTIVE) {
                (mvdReserve, stableReserve) = mvdStableAmount(IPair(pairIndice[i]));
                _totalStableReserve = _totalStableReserve.add(stableReserve);
                _totalMvdReserve = _totalMvdReserve.add(mvdReserve);
            }
        }
        _lpBacking = _totalMvdReserve > 0 ? _totalStableReserve.div(_totalMvdReserve).div(1e5) : 0;

        // Treasury Balances
        for (uint256 i = 0; i < numberOfTokens; i++) {
            if (tokens[tokenIndice[i]] == STATUS.ACTIVE) {
                _totalStableBal = _totalStableBal.add(toE18(IERC20(tokenIndice[i]).balanceOf(treasury), IERC20(tokenIndice[i]).decimals()));
            }
        }

        // Investment Balances
        for (uint256 i = 0; i < numberOfInvestments; i++) {
            if (investments[investmentIndice[i]] == STATUS.ACTIVE) {
                _totalStableBal = _totalStableBal.add(toE18(Investment(investmentIndice[i]).totalValueDeployed(), 9));
            }
        }

        _cirulatingMvd = mvdCirculation.getCirculatingSupply().sub(_totalMvdReserve);
        _treasuryBacking = _totalStableBal.div(_cirulatingMvd).div(1e5);
    }

    function mvdStableAmount(IPair _pair) public view returns (uint256 mvdReserve, uint256 stableReserve) {
        (uint256 reserve0, uint256 reserve1, ) = _pair.getReserves();
        uint8 stableDecimals;
        if (_pair.token0() == MVD) {
            mvdReserve = reserve0;
            stableReserve = reserve1;
            stableDecimals = IERC20(_pair.token1()).decimals();
        } else {
            mvdReserve = reserve1;
            stableReserve = reserve0;
            stableDecimals = IERC20(_pair.token0()).decimals();
        }
        stableReserve = toE18(stableReserve, stableDecimals);
    }

    function toE18(uint256 amount, uint8 decimals) public pure returns (uint256) {
        if (decimals == 18) return amount;
        else if (decimals > 18) return amount.div(10**(decimals - 18));
        else return amount.mul(10**(18 - decimals));
    }
}
