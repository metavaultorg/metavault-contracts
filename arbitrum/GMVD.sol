// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/libraries/Ownable.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/ERC20.sol";
import "../shared/libraries/ReentrancyGuard.sol";
import "../shared/libraries/EnumerableSet.sol";

import "./interfaces/IGMVD.sol";
import "./interfaces/IGMVDToken.sol";
import "./interfaces/IGMVDTokenUsage.sol";

contract GMVDToken is Ownable, ReentrancyGuard, ERC20("Governance MVD", "gMVD"), IGMVDToken {
    using Address for address;
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IGMVD;

    struct GMVDBalance {
        uint256 allocatedAmount;
        uint256 redeemingAmount;
    }

    struct RedeemInfo {
        uint256 mvdAmount;
        uint256 gMVDAmount;
        uint256 endTime;
        IGMVDTokenUsage dividendsAddress;
        uint256 dividendsAllocation;
    }

    IGMVD public immutable mvdToken;
    IGMVDTokenUsage public dividendsAddress;

    EnumerableSet.AddressSet private _transferWhitelist;

    mapping(address => mapping(address => uint256)) public usageApprovals;
    mapping(address => mapping(address => uint256)) public override usageAllocations;

    uint256 public constant MAX_DEALLOCATION_FEE = 200;
    mapping(address => uint256) public usagesDeallocationFee;

    uint256 public constant MAX_FIXED_RATIO = 100;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

   
    uint256 public minRedeemRatio = 50;
    uint256 public maxRedeemRatio = 100;
    uint256 public minRedeemDuration = 15 days;
    uint256 public maxRedeemDuration = 180 days;
   
    uint256 public redeemDividendsAdjustment = 50;

    mapping(address => GMVDBalance) public gMVDBalances;
    mapping(address => RedeemInfo[]) public userRedeems;

    constructor(IGMVD mvdToken_) {
        mvdToken = mvdToken_;
        _transferWhitelist.add(address(this));
    }

    /********************************************/
    /****************** EVENTS ******************/
    /********************************************/

    event ApproveUsage(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Convert(address indexed from, address to, uint256 amount);
    event UpdateRedeemSettings(uint256 minRedeemRatio, uint256 maxRedeemRatio, uint256 minRedeemDuration, uint256 maxRedeemDuration, uint256 redeemDividendsAdjustment);
    event UpdateDividendsAddress(address previousDividendsAddress, address newDividendsAddress);
    event UpdateDeallocationFee(address indexed usageAddress, uint256 fee);
    event SetTransferWhitelist(address account, bool add);
    event Redeem(address indexed userAddress, uint256 gMVDAmount, uint256 mvdAmount, uint256 duration);
    event FinalizeRedeem(address indexed userAddress, uint256 gMVDAmount, uint256 mvdAmount);
    event CancelRedeem(address indexed userAddress, uint256 gMVDAmount);
    event UpdateRedeemDividendsAddress(address indexed userAddress, uint256 redeemIndex, address previousDividendsAddress, address newDividendsAddress);
    event Allocate(address indexed userAddress, address indexed usageAddress, uint256 amount);
    event Deallocate(address indexed userAddress, address indexed usageAddress, uint256 amount, uint256 fee);

    /***********************************************/
    /****************** MODIFIERS ******************/
    /***********************************************/
    modifier validateRedeem(address userAddress, uint256 redeemIndex) {
        require(redeemIndex < userRedeems[userAddress].length, "validateRedeem: redeem entry does not exist");
        _;
    }

    /**************************************************/
    /****************** PUBLIC VIEWS ******************/
    /**************************************************/
    function getGMVDBalance(address userAddress) external view returns (uint256 allocatedAmount, uint256 redeemingAmount) {
        GMVDBalance storage balance = gMVDBalances[userAddress];
        return (balance.allocatedAmount, balance.redeemingAmount);
    }

    function getMvdByVestingDuration(uint256 amount, uint256 duration) public view returns (uint256) {
        if (duration < minRedeemDuration) {
            return 0;
        }

        if (duration > maxRedeemDuration) {
            return amount.mul(maxRedeemRatio).div(100);
        }

        uint256 ratio = minRedeemRatio.add((duration.sub(minRedeemDuration)).mul(maxRedeemRatio.sub(minRedeemRatio)).div(maxRedeemDuration.sub(minRedeemDuration)));

        return amount.mul(ratio).div(100);
    }

    function getUserRedeemsLength(address userAddress) external view returns (uint256) {
        return userRedeems[userAddress].length;
    }

    function getUserRedeem(
        address userAddress,
        uint256 redeemIndex
    )
        external
        view
        validateRedeem(userAddress, redeemIndex)
        returns (uint256 mvdAmount, uint256 gMVDAmount, uint256 endTime, address dividendsContract, uint256 dividendsAllocation)
    {
        RedeemInfo storage _redeem = userRedeems[userAddress][redeemIndex];
        return (_redeem.mvdAmount, _redeem.gMVDAmount, _redeem.endTime, address(_redeem.dividendsAddress), _redeem.dividendsAllocation);
    }

    function getUsageApproval(address userAddress, address usageAddress) external view returns (uint256) {
        return usageApprovals[userAddress][usageAddress];
    }

    function getUsageAllocation(address userAddress, address usageAddress) external view returns (uint256) {
        return usageAllocations[userAddress][usageAddress];
    }

    function transferWhitelistLength() external view returns (uint256) {
        return _transferWhitelist.length();
    }

    function transferWhitelist(uint256 index) external view returns (address) {
        return _transferWhitelist.at(index);
    }

    function isTransferWhitelisted(address account) external view override returns (bool) {
        return _transferWhitelist.contains(account);
    }

    /*******************************************************/
    /****************** OWNABLE FUNCTIONS ******************/
    /*******************************************************/
    function updateRedeemSettings(
        uint256 minRedeemRatio_,
        uint256 maxRedeemRatio_,
        uint256 minRedeemDuration_,
        uint256 maxRedeemDuration_,
        uint256 redeemDividendsAdjustment_
    ) external onlyOwner {
        require(minRedeemRatio_ <= maxRedeemRatio_, "updateRedeemSettings: wrong ratio values");
        require(minRedeemDuration_ < maxRedeemDuration_, "updateRedeemSettings: wrong duration values");
       
        require(maxRedeemRatio_ <= MAX_FIXED_RATIO && redeemDividendsAdjustment_ <= MAX_FIXED_RATIO, "updateRedeemSettings: wrong ratio values");

        minRedeemRatio = minRedeemRatio_;
        maxRedeemRatio = maxRedeemRatio_;
        minRedeemDuration = minRedeemDuration_;
        maxRedeemDuration = maxRedeemDuration_;
        redeemDividendsAdjustment = redeemDividendsAdjustment_;

        emit UpdateRedeemSettings(minRedeemRatio_, maxRedeemRatio_, minRedeemDuration_, maxRedeemDuration_, redeemDividendsAdjustment_);
    }

    function updateDividendsAddress(IGMVDTokenUsage dividendsAddress_) external onlyOwner {
       
        if (address(dividendsAddress_) == address(0)) {
            redeemDividendsAdjustment = 0;
        }

        emit UpdateDividendsAddress(address(dividendsAddress), address(dividendsAddress_));
        dividendsAddress = dividendsAddress_;
    }

    function updateDeallocationFee(address usageAddress, uint256 fee) external onlyOwner {
        require(fee <= MAX_DEALLOCATION_FEE, "updateDeallocationFee: too high");
        usagesDeallocationFee[usageAddress] = fee;
        emit UpdateDeallocationFee(usageAddress, fee);
    }

    function updateTransferWhitelist(address account, bool add) external onlyOwner {
        require(account != address(this), "updateTransferWhitelist: Cannot remove gMVD from whitelist");

        if (add) _transferWhitelist.add(account);
        else _transferWhitelist.remove(account);

        emit SetTransferWhitelist(account, add);
    }

    /*****************************************************************/
    /******************  EXTERNAL PUBLIC FUNCTIONS  ******************/
    /*****************************************************************/
    function approveUsage(IGMVDTokenUsage usage, uint256 amount) external nonReentrant {
        require(address(usage) != address(0), "approveUsage: approve to the zero address");

        usageApprovals[msg.sender][address(usage)] = amount;
        emit ApproveUsage(msg.sender, address(usage), amount);
    }

    function convert(uint256 amount) external nonReentrant {
        _convert(amount, msg.sender);
    }

    function convertTo(uint256 amount, address to) external override nonReentrant {
        require(address(msg.sender).isContract(), "convertTo: not allowed");
        _convert(amount, to);
    }

    function redeem(uint256 gMVDAmount, uint256 duration) external nonReentrant {
        require(gMVDAmount > 0, "redeem: gMVDAmount cannot be null");
        require(duration >= minRedeemDuration, "redeem: duration too low");

        _transfer(msg.sender, address(this), gMVDAmount);
        GMVDBalance storage balance = gMVDBalances[msg.sender];
        uint256 mvdAmount = getMvdByVestingDuration(gMVDAmount, duration);
        emit Redeem(msg.sender, gMVDAmount, mvdAmount, duration);

       
        if (duration > 0) {
           
            balance.redeemingAmount = balance.redeemingAmount.add(gMVDAmount);
            uint256 dividendsAllocation = gMVDAmount.mul(redeemDividendsAdjustment).div(100);
           
            if (dividendsAllocation > 0) {
                dividendsAddress.allocate(msg.sender, dividendsAllocation, new bytes(0));
            }

            userRedeems[msg.sender].push(RedeemInfo(mvdAmount, gMVDAmount, _currentBlockTimestamp().add(duration), dividendsAddress, dividendsAllocation));
        } else {
            _finalizeRedeem(msg.sender, gMVDAmount, mvdAmount);
        }
    }

    function finalizeRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        GMVDBalance storage balance = gMVDBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];
        require(_currentBlockTimestamp() >= _redeem.endTime, "finalizeRedeem: vesting duration has not ended yet");

       
        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.gMVDAmount);
        _finalizeRedeem(msg.sender, _redeem.gMVDAmount, _redeem.mvdAmount);

        if (_redeem.dividendsAllocation > 0) {
            IGMVDTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        _deleteRedeemEntry(redeemIndex);
    }

    function updateRedeemDividendsAddress(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        if (dividendsAddress != _redeem.dividendsAddress && address(dividendsAddress) != address(0)) {
            if (_redeem.dividendsAllocation > 0) {
                _redeem.dividendsAddress.deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
                dividendsAddress.allocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
            }

            emit UpdateRedeemDividendsAddress(msg.sender, redeemIndex, address(_redeem.dividendsAddress), address(dividendsAddress));
            _redeem.dividendsAddress = dividendsAddress;
        }
    }

    function cancelRedeem(uint256 redeemIndex) external nonReentrant validateRedeem(msg.sender, redeemIndex) {
        GMVDBalance storage balance = gMVDBalances[msg.sender];
        RedeemInfo storage _redeem = userRedeems[msg.sender][redeemIndex];

        balance.redeemingAmount = balance.redeemingAmount.sub(_redeem.gMVDAmount);
        _transfer(address(this), msg.sender, _redeem.gMVDAmount);

        if (_redeem.dividendsAllocation > 0) {
            IGMVDTokenUsage(_redeem.dividendsAddress).deallocate(msg.sender, _redeem.dividendsAllocation, new bytes(0));
        }

        emit CancelRedeem(msg.sender, _redeem.gMVDAmount);
        _deleteRedeemEntry(redeemIndex);
    }

    function allocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _allocate(msg.sender, usageAddress, amount);
        IGMVDTokenUsage(usageAddress).allocate(msg.sender, amount, usageData);
    }

    function allocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _allocate(userAddress, msg.sender, amount);
    }

    function deallocate(address usageAddress, uint256 amount, bytes calldata usageData) external nonReentrant {
        _deallocate(msg.sender, usageAddress, amount);
        IGMVDTokenUsage(usageAddress).deallocate(msg.sender, amount, usageData);
    }

    function deallocateFromUsage(address userAddress, uint256 amount) external override nonReentrant {
        _deallocate(userAddress, msg.sender, amount);
    }

    /********************************************************/
    /****************** INTERNAL FUNCTIONS ******************/
    /********************************************************/
    function _convert(uint256 amount, address to) internal {
        require(amount != 0, "convert: amount cannot be null");
        _mint(to, amount);
        emit Convert(msg.sender, to, amount);
        mvdToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function _finalizeRedeem(address userAddress, uint256 gMVDAmount, uint256 mvdAmount) internal {
        uint256 mvdExcess = gMVDAmount.sub(mvdAmount);

        mvdToken.safeTransfer(userAddress, mvdAmount);
        mvdToken.safeTransfer(BURN_ADDRESS, mvdExcess);
        _burn(address(this), gMVDAmount);

        emit FinalizeRedeem(userAddress, gMVDAmount, mvdAmount);
    }

    function _allocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "allocate: amount cannot be null");

        GMVDBalance storage balance = gMVDBalances[userAddress];

        uint256 approvedGMVD = usageApprovals[userAddress][usageAddress];
        require(approvedGMVD >= amount, "allocate: non authorized amount");

        usageApprovals[userAddress][usageAddress] = approvedGMVD.sub(amount);
        usageAllocations[userAddress][usageAddress] = usageAllocations[userAddress][usageAddress].add(amount);
        balance.allocatedAmount = balance.allocatedAmount.add(amount);
        _transfer(userAddress, address(this), amount);

        emit Allocate(userAddress, usageAddress, amount);
    }

    function _deallocate(address userAddress, address usageAddress, uint256 amount) internal {
        require(amount > 0, "deallocate: amount cannot be null");
        uint256 allocatedAmount = usageAllocations[userAddress][usageAddress];
        require(allocatedAmount >= amount, "deallocate: non authorized amount");
        usageAllocations[userAddress][usageAddress] = allocatedAmount.sub(amount);

        uint256 deallocationFeeAmount = amount.mul(usagesDeallocationFee[usageAddress]).div(10000);
        GMVDBalance storage balance = gMVDBalances[userAddress];
        balance.allocatedAmount = balance.allocatedAmount.sub(amount);
        _transfer(address(this), userAddress, amount.sub(deallocationFeeAmount));
       
        mvdToken.safeTransfer(BURN_ADDRESS, deallocationFeeAmount);
        _burn(address(this), deallocationFeeAmount);

        emit Deallocate(userAddress, usageAddress, amount, deallocationFeeAmount);
    }

    function _deleteRedeemEntry(uint256 index) internal {
        userRedeems[msg.sender][index] = userRedeems[msg.sender][userRedeems[msg.sender].length - 1];
        userRedeems[msg.sender].pop();
    }

    function _beforeTokenTransfer(address from, address to, uint256 /*amount*/) internal view override {
        require(from == address(0) || _transferWhitelist.contains(from) || _transferWhitelist.contains(to), "transfer: not allowed");
    }

    function _currentBlockTimestamp() internal view virtual returns (uint256) {
        /* solhint-disable not-rely-on-time */
        return block.timestamp;
    }
}
