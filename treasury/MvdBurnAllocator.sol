// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IMVD.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/ITreasury.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/interfaces/IERC20.sol";
import "../shared/interfaces/IBondCalculator.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";

interface IUniswapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

interface IPair {
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

interface ICurvePool {
    function get_dy(
        int128 i,
        int128 j,
        uint256 _dx
    ) external view returns (uint256);

    function exchange(
        int128 i,
        int128 j,
        uint256 _dx,
        uint256 _min_dy
    ) external returns (uint256);
}

/**
 *  Contract deploys reserves from treasury and send to ethereum allocator contract through anysway router,
 */

contract MvdBurnAllocator is MetaVaultAC {
    /* ======== DEPENDENCIES ======== */

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ======== STRUCTS ======== */

    struct tokenData {
        address token;
        uint256 tokenSpent;
        uint256 stableSpent;
        uint256 mvdBought;
        uint256 mvdBurnt;
        uint256 transactionLimit;
        uint256 limit;
        uint256 newLimit;
        uint256 limitChangeTimelockEnd;
    }

    /* ======== STATE VARIABLES ======== */

    ITreasury public immutable treasury; // Treasury
    string public name;

    mapping(address => tokenData) public tokenInfo; // info for reserve token to burn mvd

    uint256 public totalBought; // total mvd bought
    uint256 public totalBurnt; // total mvd burnt

    uint256 public immutable timelockInBlocks; // timelock to raise deployment limit

    bool public enableSendback;

    address public immutable mvd = 0x5C4FDfc5233f935f20D2aDbA572F770c2E377Ab0;

    address public immutable dai = 0x8D11eC38a3EB5E956B052f67Da8Bdc9bef8Abf3E;
    address public immutable usdc = 0x04068DA6C83AFCFA0e13ba15A6696662335D5B75;
    address public immutable daiMvd = 0xbc0eecdA2d8141e3a26D2535C57cadcb1095bca9;
    address public immutable usdcMvd = 0xd661952749f05aCc40503404938A91aF9aC1473b;
    address public immutable spooky = 0xF491e7B69E4244ad4002BC14e878a34207E38c29;
    address public immutable spirit = 0x16327E3FbDaCA3bcF7E38F5Af2599D2DDc33aE52;

    ICurvePool constant daiUsdc = ICurvePool(0x27E611FD27b276ACbd5Ffd632E5eAEBEC9761E40);

    /* ======== CONSTRUCTOR ======== */

    constructor(
        string memory name_,
        address _treasury,
        uint256 _timelockInBlocks,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_treasury != address(0));
        treasury = ITreasury(_treasury);

        timelockInBlocks = _timelockInBlocks;

        enableSendback = true;

        name = name_;
    }

    /* ======== OPEN FUNCTIONS ======== */

    /* ======== POLICY FUNCTIONS ======== */

    /**
     *  @notice withdraws asset from treasury, transfer out to other chain through
     *  @param token address either usdc or dai
     *  @param amount uint amount of stable coin
     */
    function burnAsset(address token, uint256 amount) public onlyPolicy {
        require(token == dai || token == usdc, "only support buyback with usdc or dai");
        require(!exceedsLimit(token, amount), "deposit amount exceed limit"); // ensure deposit is within bounds
        require(!exceedsTransactionLimit(token, amount), "transaction amount too large");
        treasury.manage(token, amount); // retrieve amount of asset from treasury
        uint256 daiAmount;
        if (token == usdc) {
            IERC20(token).approve(address(daiUsdc), amount);
            daiAmount = daiUsdc.exchange(1, 0, amount, 0);
        } else {
            daiAmount = amount;
        }

        address[] memory path = new address[](2);
        path[0] = dai;
        path[1] = mvd;
        IERC20(dai).approve(spooky, daiAmount); // approve uniswap router to spend dai
        uint256[] memory amountOuts = IUniswapRouter(spooky).swapExactTokensForTokens(daiAmount, 1, path, address(this), block.timestamp);
        uint256 bought = amountOuts[1];

        IMVD(mvd).burn(bought);

        // account for burn
        accountingFor(token, amount, amount, bought, bought);
    }

    /**
     *  @notice withdraws asset from treasury, transfer out to other chain through
     *  @param token address either usdc or dai
     *  @param amount uint amount of stable coin
     */
    function burnLp(address token, uint256 amount) public onlyPolicy {
        require(token == dai || token == usdc, "only support buyback with usdc or dai lp");
        address lpToken;
        address router;
        if (token == dai) {
            lpToken = daiMvd;
            router = spooky;
        } else {
            lpToken = usdcMvd;
            router = spirit;
        }
        require(!exceedsLimit(lpToken, amount), "deposit amount exceed limit"); // ensure deposit is within bounds
        require(!exceedsTransactionLimit(lpToken, amount), "transaction amount too large");
        (, uint256 stableReserve) = mvdStableAmount(IPair(lpToken));
        uint256 lpAmount = amount.mul(IERC20(lpToken).totalSupply()).div(stableReserve);
        treasury.manage(lpToken, lpAmount); // retrieve amount of asset from treasury
        IERC20(lpToken).approve(router, lpAmount);
        (uint256 stableAmount, uint256 mvdAmount) = IUniswapRouter(router).removeLiquidity(token, mvd, lpAmount, 0, 0, address(this), block.timestamp);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = mvd;
        IERC20(token).approve(router, stableAmount); // approve uniswap router to spend dai
        uint256[] memory amountOuts = IUniswapRouter(router).swapExactTokensForTokens(stableAmount, 1, path, address(this), block.timestamp);
        uint256 bought = amountOuts[1];

        IMVD(mvd).burn(bought.add(mvdAmount));

        // account for burn
        accountingFor(lpToken, lpAmount, stableAmount, bought, bought.add(mvdAmount));
    }

    function disableSendback() external onlyPolicy {
        enableSendback = false;
    }

    function sendBack(address _token) external onlyPolicy {
        require(enableSendback == true, "send back token is disabled");
        //require(tokenInfo[_token].underlying==address(0),"only none registered token can be sent back");
        uint256 amount = IERC20(_token).balanceOf(address(this));
        IERC20(_token).safeTransfer(authority.policy(), amount);
    }

    /**
     *  @notice adds asset token
     *  @param token address
     *  @param max uint
     *  @param transactionLimit uint
     */
    function addToken(
        address token,
        uint256 max,
        uint256 transactionLimit
    ) external onlyPolicy {
        require(token == dai || token == usdc || token == daiMvd || token == usdcMvd, "principle token invalid");
        require(tokenInfo[token].stableSpent == 0, "token is burnt already, can't re-register");

        tokenInfo[token] = tokenData({
            token: token,
            tokenSpent: 0,
            stableSpent: 0,
            mvdBought: 0,
            mvdBurnt: 0,
            transactionLimit: transactionLimit,
            limit: max,
            newLimit: 0,
            limitChangeTimelockEnd: 0
        });
    }

    /**
     *  @notice lowers max can be deployed for asset (no timelock)
     *  @param token address
     *  @param newMax uint
     */
    function lowerLimit(address token, uint256 newMax) external onlyPolicy {
        require(newMax < tokenInfo[token].limit);
        require(newMax > tokenInfo[token].stableSpent); // cannot set limit below what has been deployed already
        tokenInfo[token].limit = newMax;
        tokenInfo[token].newLimit = 0;
        tokenInfo[token].limitChangeTimelockEnd = 0;
    }

    /**
     *  @notice starts timelock to raise max allocation for asset
     *  @param token address
     *  @param newMax uint
     */
    function queueRaiseLimit(address token, uint256 newMax) external onlyPolicy {
        require(newMax > tokenInfo[token].limit, "new max must be greater than current limit");
        tokenInfo[token].limitChangeTimelockEnd = block.number.add(timelockInBlocks);
        tokenInfo[token].newLimit = newMax;
    }

    /**
     *  @notice changes max allocation for asset when timelock elapsed
     *  @param token address
     */
    function raiseLimit(address token) external onlyPolicy {
        require(block.number >= tokenInfo[token].limitChangeTimelockEnd, "Timelock not expired");
        require(tokenInfo[token].limitChangeTimelockEnd != 0, "Timelock not started");

        tokenInfo[token].limit = tokenInfo[token].newLimit;
        tokenInfo[token].newLimit = 0;
        tokenInfo[token].limitChangeTimelockEnd = 0;
    }

    function setTransactionLimit(address token, uint256 transactionLimit) external onlyPolicy {
        require(tokenInfo[token].token != address(0), "unregistered token");
        tokenInfo[token].transactionLimit = transactionLimit;
    }

    /* ======== INTERNAL FUNCTIONS ======== */

    /**
     *  @notice accounting of deposits/withdrawals of assets
     *  @param token address
     *  @param tokenSpent uint
     *  @param stableSpent uint
     *  @param mvdBought uint
     */
    function accountingFor(
        address token,
        uint256 tokenSpent,
        uint256 stableSpent,
        uint256 mvdBought,
        uint256 mvdBurnt
    ) internal {
        tokenInfo[token].tokenSpent = tokenInfo[token].tokenSpent.add(tokenSpent); // track amount allocated into pool
        tokenInfo[token].stableSpent = tokenInfo[token].stableSpent.add(stableSpent);
        tokenInfo[token].mvdBought = tokenInfo[token].mvdBought.add(mvdBought);
        tokenInfo[token].mvdBurnt = tokenInfo[token].mvdBurnt.add(mvdBurnt);
        totalBurnt = totalBurnt.add(mvdBurnt);
        totalBought = totalBought.add(mvdBought);
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice checks to ensure deposit does not exceed max allocation for asset
     *  @param token address
     *  @param stableSpent uint
     */
    function exceedsLimit(address token, uint256 stableSpent) public view returns (bool) {
        uint256 willSpent = tokenInfo[token].stableSpent.add(stableSpent);

        return (willSpent > tokenInfo[token].limit);
    }

    function exceedsTransactionLimit(address token, uint256 stableSpent) public view returns (bool) {
        return stableSpent > tokenInfo[token].transactionLimit;
    }

    function mvdStableAmount(IPair _pair) public view returns (uint256 mvdReserve, uint256 stableReserve) {
        (uint256 reserve0, uint256 reserve1, ) = _pair.getReserves();
        if (_pair.token0() == mvd) {
            mvdReserve = reserve0;
            stableReserve = reserve1;
        } else {
            mvdReserve = reserve1;
            stableReserve = reserve0;
        }
    }
}
