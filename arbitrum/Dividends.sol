// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/Ownable.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/ReentrancyGuard.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/EnumerableSet.sol";

import "./interfaces/IDividends.sol";
import "./interfaces/IGMVDTokenUsage.sol";
import "./interfaces/IWETH.sol";


contract Dividends is Ownable, ReentrancyGuard, IGMVDTokenUsage, IDividends {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct UserInfo {
    uint256 pendingDividends;
    uint256 rewardDebt;
  }

  struct DividendsInfo {
    uint256 currentDistributionAmount;
    uint256 currentCycleDistributedAmount;
    uint256 pendingAmount;
    uint256 distributedAmount;
    uint256 accDividendsPerShare;
    uint256 lastUpdateTime;
    uint256 cycleDividendsPercent;
    bool distributionDisabled;
  }

  EnumerableSet.AddressSet private _distributedTokens;
  uint256 public constant MAX_DISTRIBUTED_TOKENS = 10;
  address public immutable weth;
  mapping(address => DividendsInfo) public dividendsInfo;
  mapping(address => mapping(address => UserInfo)) public users;

  address public immutable gMVDToken;

  mapping(address => uint256) public usersAllocation;
  uint256 public totalAllocation;

  uint256 public constant MIN_CYCLE_DIVIDENDS_PERCENT = 1;
  uint256 public constant DEFAULT_CYCLE_DIVIDENDS_PERCENT = 100;
  uint256 public constant MAX_CYCLE_DIVIDENDS_PERCENT = 10000;
  uint256 internal _cycleDurationSeconds = 7 days;
  uint256 public currentCycleStartTime;

  constructor(address gMVDToken_, uint256 startTime_, address weth_) {
    require(gMVDToken_ != address(0), "zero address");
    gMVDToken = gMVDToken_;
    currentCycleStartTime = startTime_;
    weth = weth_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event UserUpdated(address indexed user, uint256 previousBalance, uint256 newBalance);
  event DividendsCollected(address indexed user, address indexed token, uint256 amount);
  event CycleDividendsPercentUpdated(address indexed token, uint256 previousValue, uint256 newValue);
  event DividendsAddedToPending(address indexed token, uint256 amount);
  event DistributedTokenDisabled(address indexed token);
  event DistributedTokenRemoved(address indexed token);
  event DistributedTokenEnabled(address indexed token);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  modifier validateDistributedTokensIndex(uint256 index) {
    require(index < _distributedTokens.length(), "validateDistributedTokensIndex: index exists?");
    _;
  }

  modifier validateDistributedToken(address token) {
    require(_distributedTokens.contains(token), "validateDistributedTokens: token does not exists");
    _;
  }

  modifier gMVDTokenOnly() {
    require(msg.sender == gMVDToken, "gMVDTokenOnly: caller should be gMVDToken");
    _;
  }

  /*******************************************/
  /****************** VIEWS ******************/
  /*******************************************/

  function cycleDurationSeconds() external view returns (uint256) {
    return _cycleDurationSeconds;
  }

  function distributedTokensLength() external view override returns (uint256) {
    return _distributedTokens.length();
  }

  function distributedToken(uint256 index) external view override validateDistributedTokensIndex(index) returns (address){
    return address(_distributedTokens.at(index));
  }

  function isDistributedToken(address token) external view override returns (bool) {
    return _distributedTokens.contains(token);
  }

  function nextCycleStartTime() public view returns (uint256) {
    return currentCycleStartTime.add(_cycleDurationSeconds);
  }

  function pendingDividendsAmount(address token, address userAddress) external view returns (uint256) {
    if (totalAllocation == 0) {
      return 0;
    }

    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
    uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
    uint256 dividendAmountPerSecond_ = _dividendsAmountPerSecond(token);

    // check if the current cycle has changed since last update
    if (_currentBlockTimestamp() > nextCycleStartTime()) {
      // get remaining rewards from last cycle
      accDividendsPerShare = accDividendsPerShare.add(
        (nextCycleStartTime().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e7).div(totalAllocation)
      );
      lastUpdateTime = nextCycleStartTime();
      dividendAmountPerSecond_ = dividendsInfo_.pendingAmount.mul(dividendsInfo_.cycleDividendsPercent).div(100).div(
        _cycleDurationSeconds
      );
    }

    accDividendsPerShare = accDividendsPerShare.add(
      (_currentBlockTimestamp().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e7).div(totalAllocation)
    );

    return usersAllocation[userAddress]
        .mul(accDividendsPerShare)
        .div(1e9)
        .sub(users[token][userAddress].rewardDebt)
        .add(users[token][userAddress].pendingDividends);
  }

  /**************************************************/
  /****************** PUBLIC FUNCTIONS **************/
  /**************************************************/

  function updateCurrentCycleStartTime() public {
    uint256 nextCycleStartTime_ = nextCycleStartTime();

    if (_currentBlockTimestamp() >= nextCycleStartTime_) {
      currentCycleStartTime = nextCycleStartTime_;
    }
  }

  function updateDividendsInfo(address token) external validateDistributedToken(token) {
    _updateDividendsInfo(token);
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  function massUpdateDividendsInfo() external {
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      _updateDividendsInfo(_distributedTokens.at(index));
    }
  }

  function harvestDividends(address token, bool withdrawEth) external nonReentrant {
    if (!_distributedTokens.contains(token)) {
      require(dividendsInfo[token].distributedAmount > 0, "harvestDividends: invalid token");
    }

    _harvestDividends(token, withdrawEth);
  }

  function harvestAllDividends(bool withdrawEth) external nonReentrant {
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      _harvestDividends(_distributedTokens.at(index), withdrawEth);
    }
  }

  function addDividendsToPending(address token, uint256 amount) external override nonReentrant {
    uint256 prevTokenBalance = IERC20(token).balanceOf(address(this));
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    uint256 receivedAmount = IERC20(token).balanceOf(address(this)).sub(prevTokenBalance);
    dividendsInfo_.pendingAmount = dividendsInfo_.pendingAmount.add(receivedAmount);

    emit DividendsAddedToPending(token, receivedAmount);
  }

  function emergencyWithdraw(IERC20 token) public nonReentrant onlyOwner {
    uint256 balance = token.balanceOf(address(this));
    require(balance > 0, "emergencyWithdraw: token balance is null");
    _safeTokenTransfer(token, msg.sender, balance);
  }

  function emergencyWithdrawAll() external nonReentrant onlyOwner {
    for (uint256 index = 0; index < _distributedTokens.length(); ++index) {
      emergencyWithdraw(IERC20(_distributedTokens.at(index)));
    }
  }

  /*****************************************************************/
  /****************** OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  function allocate(address userAddress, uint256 amount, bytes calldata /*data*/) external override nonReentrant gMVDTokenOnly {
    uint256 newUserAllocation = usersAllocation[userAddress].add(amount);
    uint256 newTotalAllocation = totalAllocation.add(amount);
    _updateUser(userAddress, newUserAllocation, newTotalAllocation);
  }

  function deallocate(address userAddress, uint256 amount, bytes calldata /*data*/) external override nonReentrant gMVDTokenOnly {
    uint256 newUserAllocation = usersAllocation[userAddress].sub(amount);
    uint256 newTotalAllocation = totalAllocation.sub(amount);
    _updateUser(userAddress, newUserAllocation, newTotalAllocation);
  }

  function enableDistributedToken(address token) external onlyOwner {
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    require(
      dividendsInfo_.lastUpdateTime == 0 || dividendsInfo_.distributionDisabled,
      "enableDistributedToken: Already enabled dividends token"
    );
    require(_distributedTokens.length() < MAX_DISTRIBUTED_TOKENS, "enableDistributedToken: too many distributedTokens");
    if (dividendsInfo_.lastUpdateTime == 0) {
      dividendsInfo_.lastUpdateTime = _currentBlockTimestamp();
    }
    if (dividendsInfo_.cycleDividendsPercent == 0) {
      dividendsInfo_.cycleDividendsPercent = DEFAULT_CYCLE_DIVIDENDS_PERCENT;
    }
    dividendsInfo_.distributionDisabled = false;
    _distributedTokens.add(token);
    emit DistributedTokenEnabled(token);
  }

  function disableDistributedToken(address token) external onlyOwner {
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    require(
      dividendsInfo_.lastUpdateTime > 0 && !dividendsInfo_.distributionDisabled,
      "disableDistributedToken: Already disabled dividends token"
    );
    dividendsInfo_.distributionDisabled = true;
    emit DistributedTokenDisabled(token);
  }

  function updateCycleDividendsPercent(address token, uint256 percent) external onlyOwner {
    require(percent <= MAX_CYCLE_DIVIDENDS_PERCENT, "updateCycleDividendsPercent: percent mustn't exceed maximum");
    require(percent >= MIN_CYCLE_DIVIDENDS_PERCENT, "updateCycleDividendsPercent: percent mustn't exceed minimum");
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    uint256 previousPercent = dividendsInfo_.cycleDividendsPercent;
    dividendsInfo_.cycleDividendsPercent = percent;
    emit CycleDividendsPercentUpdated(token, previousPercent, dividendsInfo_.cycleDividendsPercent);
  }

  function removeTokenFromDistributedTokens(address tokenToRemove) external onlyOwner {
    DividendsInfo storage _dividendsInfo = dividendsInfo[tokenToRemove];
    require(_dividendsInfo.distributionDisabled && _dividendsInfo.currentDistributionAmount == 0, "removeTokenFromDistributedTokens: cannot be removed");
    _distributedTokens.remove(tokenToRemove);
    emit DistributedTokenRemoved(tokenToRemove);
  }

  function updateCycleDurationSeconds(uint256 cycleDurationSeconds_) external onlyOwner {
    require(cycleDurationSeconds_ >= 7 days, "Dividends: Min cycle duration");
    require(cycleDurationSeconds_ <= 60 days, "Dividends: Max cycle duration");
    _cycleDurationSeconds = cycleDurationSeconds_;
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  function _dividendsAmountPerSecond(address token) internal view returns (uint256) {
    if (!_distributedTokens.contains(token)) return 0;
    return dividendsInfo[token].currentDistributionAmount.mul(1e2).div(_cycleDurationSeconds);
  }

  function _updateDividendsInfo(address token) internal {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    updateCurrentCycleStartTime();

    uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
    uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
    if (currentBlockTimestamp <= lastUpdateTime) {
      return;
    }

    if (totalAllocation == 0 || currentBlockTimestamp < currentCycleStartTime) {
      dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
      return;
    }

    uint256 currentDistributionAmount = dividendsInfo_.currentDistributionAmount;
    uint256 currentCycleDistributedAmount = dividendsInfo_.currentCycleDistributedAmount;

    if (lastUpdateTime < currentCycleStartTime) {
      accDividendsPerShare = accDividendsPerShare.add(
        (currentDistributionAmount.mul(1e2).sub(currentCycleDistributedAmount))
          .mul(1e7)
          .div(totalAllocation)
      );

      if (!dividendsInfo_.distributionDisabled) {
        dividendsInfo_.distributedAmount = dividendsInfo_.distributedAmount.add(currentDistributionAmount);

        uint256 pendingAmount = dividendsInfo_.pendingAmount;
        currentDistributionAmount = pendingAmount.mul(dividendsInfo_.cycleDividendsPercent).div(
          10000
        );
        dividendsInfo_.currentDistributionAmount = currentDistributionAmount;
        dividendsInfo_.pendingAmount = pendingAmount.sub(currentDistributionAmount);
      } else {
        dividendsInfo_.distributedAmount = dividendsInfo_.distributedAmount.add(currentDistributionAmount);
        currentDistributionAmount = 0;
        dividendsInfo_.currentDistributionAmount = 0;
      }

      currentCycleDistributedAmount = 0;
      lastUpdateTime = currentCycleStartTime;
    }

    uint256 toDistribute = (currentBlockTimestamp.sub(lastUpdateTime)).mul(_dividendsAmountPerSecond(token));
    // ensure that we can't distribute more than currentDistributionAmount (for instance w/ a > 24h service interruption)
    if (currentCycleDistributedAmount.add(toDistribute) > currentDistributionAmount.mul(1e2)) {
      toDistribute = currentDistributionAmount.mul(1e2).sub(currentCycleDistributedAmount);
    }

    dividendsInfo_.currentCycleDistributedAmount = currentCycleDistributedAmount.add(toDistribute);
    dividendsInfo_.accDividendsPerShare = accDividendsPerShare.add(toDistribute.mul(1e7).div(totalAllocation));
    dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
  }

  function _updateUser(address userAddress, uint256 newUserAllocation, uint256 newTotalAllocation) internal {
    uint256 previousUserAllocation = usersAllocation[userAddress];

    // for each distributedToken
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      address token = _distributedTokens.at(index);
      _updateDividendsInfo(token);

      UserInfo storage user = users[token][userAddress];
      uint256 accDividendsPerShare = dividendsInfo[token].accDividendsPerShare;

      uint256 pending = previousUserAllocation.mul(accDividendsPerShare).div(1e9).sub(user.rewardDebt);
      user.pendingDividends = user.pendingDividends.add(pending);
      user.rewardDebt = newUserAllocation.mul(accDividendsPerShare).div(1e9);
    }

    usersAllocation[userAddress] = newUserAllocation;
    totalAllocation = newTotalAllocation;

    emit UserUpdated(userAddress, previousUserAllocation, newUserAllocation);
  }

  function _harvestDividends(address token, bool withdrawEth) internal {
    _updateDividendsInfo(token);

    UserInfo storage user = users[token][msg.sender];
    uint256 accDividendsPerShare = dividendsInfo[token].accDividendsPerShare;

    uint256 userGMVDAllocation = usersAllocation[msg.sender];
    uint256 pending = user.pendingDividends.add(
      userGMVDAllocation.mul(accDividendsPerShare).div(1e9).sub(user.rewardDebt)
    );

    user.pendingDividends = 0;
    user.rewardDebt = userGMVDAllocation.mul(accDividendsPerShare).div(1e9);

    if(withdrawEth && token == weth ){
      _transferOutETH(pending, payable(msg.sender));
    } else {
      _safeTokenTransfer(IERC20(token), msg.sender, pending);
    }
    emit DividendsCollected(msg.sender, token, pending);
  }

  function _transferOutETH(uint256 _amountOut, address payable _receiver) internal {
    IWETH _weth = IWETH(weth);
    _weth.withdraw(_amountOut);

    (bool success, /* bytes memory data */) = _receiver.call{ value: _amountOut }("");

    if (success) { return; }

    _weth.deposit{ value: _amountOut }();
    _weth.transfer(address(_receiver), _amountOut);
  }

  receive() external payable {
      require(msg.sender == weth, "Dividends: invalid sender");
  }

  function _safeTokenTransfer(
    IERC20 token,
    address to,
    uint256 amount
  ) internal {
    if (amount > 0) {
      uint256 tokenBal = token.balanceOf(address(this));
      if (amount > tokenBal) {
        token.safeTransfer(to, tokenBal);
      } else {
        token.safeTransfer(to, amount);
      }
    }
  }

  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    /* solhint-disable not-rely-on-time */
    return block.timestamp;
  }
}