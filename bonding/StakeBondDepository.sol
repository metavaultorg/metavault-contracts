// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

import "../shared/interfaces/IBondCalculator.sol";
import "../shared/interfaces/IBackingCalculator.sol";
import "../shared/interfaces/ITreasury.sol";
import "../shared/interfaces/IStakingManager.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/FixedPoint.sol";

contract StakeBondDepository is MetaVaultAC {
    using FixedPoint for *;
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    /* ======== EVENTS ======== */

    event BondCreated(uint256 deposit, uint256 indexed payout, uint256 indexed expires, uint256 indexed priceInUSD);
    event BondRedeemed(address indexed recipient, uint256 payout, uint256 remaining);
    event BondPriceChanged(uint256 indexed priceInUSD, uint256 indexed internalPrice, uint256 indexed debtRatio);
    event ControlVariableAdjustment(uint256 initialBCV, uint256 newBCV, uint256 adjustment, bool addition);

    /* ======== STATE VARIABLES ======== */

    address public immutable MVD; // intermediate reward token from treasury
    address public immutable sMVD; // token given as payment for bond
    address public immutable principle; // token used to create bond
    address public immutable treasury; // mints MVD when receives principle
    address public immutable DAO; // receives profit share from bond

    bool public immutable isLiquidityBond; // LP and Reserve bonds are treated slightly different
    address public immutable bondCalculator; // calculates value of LP tokens

    address public stakingManager; // to stake and claim

    Terms public terms; // stores terms for new bonds
    Adjust public adjustment; // stores adjustment to BCV data

    mapping(address => Bond) public _bondInfo; // stores bond information for depositors

    uint256 public totalDebt; // total value of outstanding bonds; used for pricing
    uint256 public lastDecay; // reference time for debt decay

    uint256 public totalPrinciple; // total principle bonded through this depository

    string internal name_; //name of this bond
    IBackingCalculator public backingCalculator;
    uint8 public principleDecimals; //principle decimals or pair markdown decimals
    uint8 public premium; //percent , 20%=20

    /* ======== STRUCTS ======== */

    // Info for creating new bonds
    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 vestingTerm; // in blocks
        uint256 minimumPrice; // vs principle value , 4 decimals 0.15 = 1500
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }

    // Info for bond holder with gons
    struct Bond {
        uint256 gonsPayout; // sMVD gons remaining to be paid
        uint256 mvdPayout; //mvd amount at the moment of bond
        uint256 vesting; // Blocks left to vest
        uint256 lastTime; // Last interaction
        uint256 pricePaid; // In DAI, for front end viewing
    }

    // Info for incremental adjustments to control variable
    struct Adjust {
        bool add; // addition or subtraction
        uint256 rate; // increment
        uint256 target; // BCV when adjustment finished
        uint256 buffer; // minimum length (in blocks) between adjustments
        uint256 lastTime; // time when last adjustment made
    }

    /* ======== INITIALIZATION ======== */

    constructor(
        string memory _name,
        address _MVD,
        address _sMVD,
        address _principle,
        uint8 _principleDecimals,
        address _treasury,
        address _DAO,
        address _backingCalculator,
        address _bondCalculator,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require(_MVD != address(0));
        MVD = _MVD;
        require(_sMVD != address(0));
        sMVD = _sMVD;
        require(_principle != address(0));
        principle = _principle;
        require(_principleDecimals != 0);
        principleDecimals = _principleDecimals;
        require(_treasury != address(0));
        treasury = _treasury;
        require(_DAO != address(0));
        DAO = _DAO;
        require(address(0) != _backingCalculator);
        backingCalculator = IBackingCalculator(_backingCalculator);
        // bondCalculator should be address(0) if not LP bond
        bondCalculator = _bondCalculator;
        isLiquidityBond = (_bondCalculator != address(0));
        name_ = _name;
        premium = 20;
    }

    /**
     *  @notice initializes bond parameters
     *  @param _controlVariable uint
     *  @param _vestingTerm uint
     *  @param _minimumPrice uint
     *  @param _maxPayout uint
     *  @param _fee uint
     *  @param _maxDebt uint
     *  @param _initialDebt uint
     */
    function initializeBondTerms(
        uint256 _controlVariable,
        uint256 _vestingTerm,
        uint256 _minimumPrice,
        uint256 _maxPayout,
        uint256 _fee,
        uint256 _maxDebt,
        uint256 _initialDebt
    ) external onlyPolicy {
        terms = Terms({controlVariable: _controlVariable, vestingTerm: _vestingTerm, minimumPrice: _minimumPrice, maxPayout: _maxPayout, fee: _fee, maxDebt: _maxDebt});
        totalDebt = _initialDebt;
        lastDecay = block.number;
    }

    /* ======== POLICY FUNCTIONS ======== */

    enum PARAMETER {
        VESTING,
        PAYOUT,
        FEE,
        DEBT,
        MINPRICE
    }

    /**
     *  @notice set parameters for new bonds
     *  @param _parameter PARAMETER
     *  @param _input uint
     */
    function setBondTerms(PARAMETER _parameter, uint256 _input) external onlyPolicy {
        if (_parameter == PARAMETER.VESTING) {
            // 0
            require(_input >= 10000, "Vesting must be longer than 3 hours");
            terms.vestingTerm = _input;
        } else if (_parameter == PARAMETER.PAYOUT) {
            // 1
            require(_input <= 1000, "Payout cannot be above 1 percent");
            terms.maxPayout = _input;
        } else if (_parameter == PARAMETER.FEE) {
            // 2
            require(_input <= 10000, "DAO fee cannot exceed payout");
            terms.fee = _input;
        } else if (_parameter == PARAMETER.DEBT) {
            // 3
            terms.maxDebt = _input;
        } else if (_parameter == PARAMETER.MINPRICE) {
            // 4
            terms.minimumPrice = _input;
        }
    }

    /**
     *  @notice set control variable adjustment
     *  @param _addition bool
     *  @param _increment uint
     *  @param _target uint
     *  @param _buffer uint
     */
    function setAdjustment(
        bool _addition,
        uint256 _increment,
        uint256 _target,
        uint256 _buffer
    ) external onlyPolicy {
        adjustment = Adjust({add: _addition, rate: _increment, target: _target, buffer: _buffer, lastTime: block.number});
    }

    /**
     *  @notice set contract for auto stake
     *  @param _manager address
     */
    function setStakingManager(address _manager) external onlyPolicy {
        require(_manager != address(0));
        stakingManager = _manager;
    }

    /* ======== USER FUNCTIONS ======== */

    /**
     *  @notice deposit bond
     *  @param _amount uint
     *  @param _maxPrice uint
     *  @param _depositor address
     *  @return uint
     */
    function deposit(
        uint256 _amount,
        uint256 _maxPrice,
        address _depositor
    ) external returns (uint256) {
        require(_depositor != address(0), "Invalid address");

        decayDebt();
        require(totalDebt <= terms.maxDebt, "Max capacity reached");

        uint256 priceInUSD = bondPriceInUSD(); // Stored in bond info
        //uint nativePrice = _bondPrice();

        require(_maxPrice >= _bondPrice(), "Slippage limit: more than max price"); // slippage protection

        uint256 value = ITreasury(treasury).valueOf(principle, _amount);
        uint256 payout = payoutFor(value); // payout to bonder is computed

        require(payout >= 10000000, "Bond too small"); // must be > 0.01 MVD ( underflow protection )
        require(payout <= maxPayout(), "Bond too large"); // size protection because there is no slippage

        // profits are calculated
        uint256 fee = payout.mul(terms.fee).div(10000);
        uint256 profit = value.sub(payout).sub(fee);

        /**
            principle is transferred in
            approved and
            deposited into the treasury, returning (_amount - profit) MVD
         */
        IERC20(principle).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(principle).approve(address(treasury), _amount);
        ITreasury(treasury).deposit(_amount, principle, profit);

        totalPrinciple = totalPrinciple.add(_amount);

        if (fee != 0) {
            // fee is transferred to dao
            IERC20(MVD).safeTransfer(DAO, fee);
        }

        // total debt is increased
        totalDebt = totalDebt.add(value);
        //TODO
        //uint stakeAmount = totalBond.sub(fee);

        IERC20(MVD).approve(stakingManager, payout);

        IStakingManager(stakingManager).stake(payout, address(this));
        /* ---------------------------------------------------------- */

        uint256 stakeGons = IsMVD(sMVD).gonsForBalance(payout);

        // depositor info is stored
        _bondInfo[_depositor] = Bond({
            gonsPayout: _bondInfo[_depositor].gonsPayout.add(stakeGons),
            mvdPayout: _bondInfo[_depositor].mvdPayout.add(payout),
            vesting: terms.vestingTerm,
            lastTime: block.number,
            pricePaid: priceInUSD
        });

        // indexed events are emitted
        emit BondCreated(_amount, payout, block.number.add(terms.vestingTerm), priceInUSD);
        emit BondPriceChanged(bondPriceInUSD(), _bondPrice(), debtRatio());

        adjust(); // control variable is adjusted
        return payout;
    }

    /**
     *  @notice redeem bond for user, keep the parameter bool _stake for compatibility of redeem helper
     *  @param _recipient address
     *  @param _stake bool
     *  @return uint
     */
    function redeem(address _recipient, bool _stake) external returns (uint256) {
        Bond memory info = _bondInfo[_recipient];
        uint256 percentVested = percentVestedFor(_recipient); // (blocks since last interaction / vesting term remaining)

        require(percentVested >= 10000, "not yet fully vested"); // if fully vested

        IStakingManager(stakingManager).claim(address(this));

        delete _bondInfo[_recipient]; // delete user info
        uint256 _amount = IsMVD(sMVD).balanceForGons(info.gonsPayout);
        emit BondRedeemed(_recipient, _amount, 0); // emit bond data
        IERC20(sMVD).transfer(_recipient, _amount); // pay user everything due
        return _amount;
    }

    /* ======== INTERNAL HELPER FUNCTIONS ======== */

    /**
     *  @notice makes incremental adjustment to control variable
     */
    function adjust() internal {
        uint256 blockCanAdjust = adjustment.lastTime.add(adjustment.buffer);
        if (adjustment.rate != 0 && block.number >= blockCanAdjust) {
            uint256 initial = terms.controlVariable;
            if (adjustment.add) {
                terms.controlVariable = terms.controlVariable.add(adjustment.rate);
                if (terms.controlVariable >= adjustment.target) {
                    adjustment.rate = 0;
                }
            } else {
                terms.controlVariable = terms.controlVariable.sub(adjustment.rate);
                if (terms.controlVariable <= adjustment.target) {
                    adjustment.rate = 0;
                }
            }
            adjustment.lastTime = block.number;
            emit ControlVariableAdjustment(initial, terms.controlVariable, adjustment.rate, adjustment.add);
        }
    }

    /**
     *  @notice reduce total debt
     */
    function decayDebt() internal {
        totalDebt = totalDebt.sub(debtDecay());
        lastDecay = block.number;
    }

    function setBackingCalculator(address _backingCalculator) external onlyPolicy {
        require(address(0) != _backingCalculator);
        backingCalculator = IBackingCalculator(_backingCalculator);
    }

    function setPrincipleDecimals(uint8 _principleDecimals) external onlyPolicy {
        require(_principleDecimals != 0);
        principleDecimals = _principleDecimals;
    }

    function setPremium(uint8 _premium) external onlyPolicy {
        premium = _premium;
    }

    /* ======== VIEW FUNCTIONS ======== */

    /**
     *  @notice determine maximum bond size
     *  @return uint
     */
    function maxPayout() public view returns (uint256) {
        return IERC20(MVD).totalSupply().mul(terms.maxPayout).div(100000);
    }

    /**
     *  @notice calculate interest due for new bond
     *  @param _value uint
     *  @return uint
     */
    function payoutFor(uint256 _value) public view returns (uint256) {
        return FixedPoint.fraction(_value, bondPrice()).decode112with18().div(1e14);
    }

    /**
     *  @notice calculate current bond premium
     *  @return price_ uint
     */
    function bondPrice() public view returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(1000000000).div(1e5);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        }
        uint256 bph = backingCalculator.treasuryBacking(); //1e4
        uint256 nativeBph = toNativePrice(bph); //1e4
        if (price_ < nativeBph) {
            price_ = nativeBph.mul(uint256(100).add(premium)).div(100);
        }
    }

    function toNativePrice(uint256 _bph) public view returns (uint256 _nativeBph) {
        if (isLiquidityBond) _nativeBph = _bph.mul(10**principleDecimals).div(IBondCalculator(bondCalculator).markdown(principle));
        else _nativeBph = _bph;
    }

    /**
     *  @notice calculate current bond price and remove floor if above
     *  @return price_ uint
     */
    function _bondPrice() internal returns (uint256 price_) {
        price_ = terms.controlVariable.mul(debtRatio()).add(1000000000).div(1e5);
        if (price_ < terms.minimumPrice) {
            price_ = terms.minimumPrice;
        } else if (terms.minimumPrice != 0) {
            terms.minimumPrice = 0;
        }
        uint256 bph = backingCalculator.treasuryBacking(); //1e4
        uint256 nativeBph = toNativePrice(bph); //1e4
        if (price_ < nativeBph) {
            price_ = nativeBph.mul(uint256(100).add(premium)).div(100);
        }
    }

    /**
     *  @notice converts bond price to DAI value
     *  @return price_ uint
     */
    function bondPriceInUSD() public view returns (uint256 price_) {
        if (isLiquidityBond) {
            price_ = bondPrice().mul(IBondCalculator(bondCalculator).markdown(principle)).div(1e4);
        } else {
            price_ = bondPrice().mul(10**IERC20(principle).decimals()).div(1e4);
        }
    }

    /**
     *  @notice return bond info with latest sMVD balance calculated from gons
     *  @param _depositor address
     *  @return payout uint
     *  @return vesting uint
     *  @return lastTime uint
     *  @return pricePaid uint
     */
    function bondInfo(address _depositor)
        public
        view
        returns (
            uint256 payout,
            uint256 vesting,
            uint256 lastTime,
            uint256 pricePaid
        )
    {
        Bond memory info = _bondInfo[_depositor];
        payout = IsMVD(sMVD).balanceForGons(info.gonsPayout);
        vesting = info.vesting;
        lastTime = info.lastTime;
        pricePaid = info.pricePaid;
    }

    /**
     *  @notice calculate current ratio of debt to MVD supply
     *  @return debtRatio_ uint
     */
    function debtRatio() public view returns (uint256 debtRatio_) {
        uint256 supply = IERC20(MVD).totalSupply();
        debtRatio_ = FixedPoint.fraction(currentDebt().mul(1e9), supply).decode112with18().div(1e18);
    }

    /**
     *  @notice debt ratio in same terms for reserve or liquidity bonds
     *  @return uint
     */
    function standardizedDebtRatio() external view returns (uint256) {
        if (isLiquidityBond) {
            return debtRatio().mul(IBondCalculator(bondCalculator).markdown(principle)).div(1e9);
        } else {
            return debtRatio();
        }
    }

    /**
     *  @notice calculate debt factoring in decay
     *  @return uint
     */
    function currentDebt() public view returns (uint256) {
        return totalDebt.sub(debtDecay());
    }

    /**
     *  @notice amount to decay total debt by
     *  @return decay_ uint
     */
    function debtDecay() public view returns (uint256 decay_) {
        uint256 blocksSinceLast = block.number.sub(lastDecay);
        decay_ = totalDebt.mul(blocksSinceLast).div(terms.vestingTerm);
        if (decay_ > totalDebt) {
            decay_ = totalDebt;
        }
    }

    /**
     *  @notice calculate how far into vesting a depositor is
     *  @param _depositor address
     *  @return percentVested_ uint
     */
    function percentVestedFor(address _depositor) public view returns (uint256 percentVested_) {
        Bond memory bond = _bondInfo[_depositor];
        uint256 blocksSinceLast = block.number.sub(bond.lastTime);
        uint256 vesting = bond.vesting;

        if (vesting > 0) {
            percentVested_ = blocksSinceLast.mul(10000).div(vesting);
        } else {
            percentVested_ = 0;
        }
    }

    /**
     *  @notice calculate amount of MVD available for claim by depositor
     *  @param _depositor address
     *  @return pendingPayout_ uint
     */
    function pendingPayoutFor(address _depositor) external view returns (uint256 pendingPayout_) {
        uint256 percentVested = percentVestedFor(_depositor);
        uint256 payout = IsMVD(sMVD).balanceForGons(_bondInfo[_depositor].gonsPayout);

        if (percentVested >= 10000) {
            pendingPayout_ = payout;
        } else {
            pendingPayout_ = 0;
        }
    }

    /**
     *  @notice show the name of current bond
     *  @return _name string
     */
    function name() public view returns (string memory _name) {
        return name_;
    }

    /* ======= AUXILLIARY ======= */

    /**
     *  @notice allow anyone to send lost tokens (excluding principle or MVD) to the DAO
     *  @return bool
     */
    function recoverLostToken(address _token) external returns (bool) {
        require(_token != MVD);
        require(_token != sMVD);
        require(_token != principle);
        IERC20(_token).safeTransfer(DAO, IERC20(_token).balanceOf(address(this)));
        return true;
    }
}
