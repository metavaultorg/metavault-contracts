// SPDX-License-Identifier: MIT
pragma solidity 0.7.5;

import "../shared/libraries/SafeMath.sol";
import "../shared/interfaces/IsMVD.sol";
import "../shared/interfaces/IgMVD.sol";
import "../shared/interfaces/IWarmup.sol";
import "../shared/interfaces/IDistributor.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeERC20.sol";


contract Staking is MetaVaultAC {

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public immutable MVD;
    address public immutable sMVD;

    struct Epoch {
        uint256 length; // in seconds
        uint256 number; // since inception
        uint256 endBlock; // timestamp
        uint256 distribute; // amount
    }
    Epoch public epoch;

    address public distributor;
    
    address public locker;
    uint public totalBonus;
    
    address public warmupContract;
    uint public warmupPeriod;
    
    constructor ( 
        address _MVD, 
        address _sMVD, 
        uint _epochLength,
        uint _firstEpochNumber,
        uint _firstEpochBlock,
        address _authority
    ) MetaVaultAC(IMetaVaultAuthority(_authority)) {
        require( _MVD != address(0) );
        MVD = _MVD;
        require( _sMVD != address(0) );
        sMVD = _sMVD;
        
        epoch = Epoch({
            length: _epochLength,
            number: _firstEpochNumber,
            endBlock: _firstEpochBlock,
            distribute: 0
        });
    }

    struct Claim {
        uint deposit;
        uint gons;
        uint expiry;
        bool lock; // prevents malicious delays
    }
    mapping( address => Claim ) public warmupInfo;

    /**
        @notice stake MVD to enter warmup
        @param _amount uint
        @return bool
     */
    function stake( uint _amount, address _recipient ) external returns ( bool ) {
        rebase();
        
        IERC20( MVD ).safeTransferFrom( msg.sender, address(this), _amount );

        Claim memory info = warmupInfo[ _recipient ];
        require( !info.lock, "Deposits for account are locked" );

        warmupInfo[ _recipient ] = Claim ({
            deposit: info.deposit.add( _amount ),
            gons: info.gons.add( IsMVD( sMVD ).gonsForBalance( _amount ) ),
            expiry: epoch.number.add( warmupPeriod ),
            lock: false
        });
        
        IERC20( sMVD ).safeTransfer( warmupContract, _amount );
        return true;
    }

    /**
        @notice retrieve sMVD from warmup
        @param _recipient address
     */
    function claim ( address _recipient ) public {
        Claim memory info = warmupInfo[ _recipient ];
        if ( epoch.number >= info.expiry && info.expiry != 0 ) {
            delete warmupInfo[ _recipient ];
            IWarmup( warmupContract ).retrieve( _recipient, IsMVD( sMVD ).balanceForGons( info.gons ) );
        }
    }

    /**
        @notice forfeit sMVD in warmup and retrieve MVD
     */
    function forfeit() external {
        Claim memory info = warmupInfo[ msg.sender ];
        delete warmupInfo[ msg.sender ];

        IWarmup( warmupContract ).retrieve( address(this), IsMVD( sMVD ).balanceForGons( info.gons ) );
        IERC20( MVD ).safeTransfer( msg.sender, info.deposit );
    }

    /**
        @notice prevent new deposits to address (protection from malicious activity)
     */
    function toggleDepositLock() external {
        warmupInfo[ msg.sender ].lock = !warmupInfo[ msg.sender ].lock;
    }

    /**
        @notice redeem sMVD for MVD
        @param _amount uint
        @param _trigger bool
     */
    function unstake( uint _amount, bool _trigger ) external {
        if ( _trigger ) {
            rebase();
        }
        IERC20( sMVD ).safeTransferFrom( msg.sender, address(this), _amount );
        IERC20( MVD ).safeTransfer( msg.sender, _amount );
    }

    /**
        @notice returns the sMVD index, which tracks rebase growth
        @return uint
     */
    function index() public view returns ( uint ) {
        return IsMVD( sMVD ).index();
    }

    /**
        @notice trigger rebase if epoch over
     */
    function rebase() public {
        if( epoch.endBlock <= block.number ) {

            IsMVD( sMVD ).rebase( epoch.distribute, epoch.number );

            epoch.endBlock = epoch.endBlock.add( epoch.length );
            epoch.number++;
            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }

            uint balance = contractBalance();
            uint staked = IsMVD( sMVD ).circulatingSupply();

            if( balance <= staked ) {
                epoch.distribute = 0;
            } else {
                epoch.distribute = balance.sub( staked );
            }
        }
    }

    /**
        @notice returns contract MVD holdings, including bonuses provided
        @return uint
     */
    function contractBalance() public view returns ( uint ) {
        return IERC20( MVD ).balanceOf( address(this) ).add( totalBonus );
    }

    /**
        @notice provide bonus to locked staking contract
        @param _amount uint
     */
    function giveLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = totalBonus.add( _amount );
        IERC20( sMVD ).safeTransfer( locker, _amount );
    }

    /**
        @notice reclaim bonus from locked staking contract
        @param _amount uint
     */
    function returnLockBonus( uint _amount ) external {
        require( msg.sender == locker );
        totalBonus = totalBonus.sub( _amount );
        IERC20( sMVD ).safeTransferFrom( locker, address(this), _amount );
    }

    enum CONTRACTS { DISTRIBUTOR, WARMUP, LOCKER }

    /**
        @notice sets the contract address for LP staking
        @param _contract address
     */
    function setContract( CONTRACTS _contract, address _address ) external onlyGovernor() {
        if( _contract == CONTRACTS.DISTRIBUTOR ) { // 0
            distributor = _address;
        } else if ( _contract == CONTRACTS.WARMUP ) { // 1
            require( warmupContract == address( 0 ), "Warmup cannot be set more than once" );
            warmupContract = _address;
        } else if ( _contract == CONTRACTS.LOCKER ) { // 2
            require( locker == address(0), "Locker cannot be set more than once" );
            locker = _address;
        }
    }

    /**
        @notice sets the epoch length
        @param _epochLength length
     */
    function setEpochLength( uint _epochLength ) external onlyGovernor() {
        epoch.length = _epochLength;
    }

    /**
        @notice sets the epoch end block
        @param _epochEndBlock end block
     */
    function setEpochEnd( uint _epochEndBlock ) external onlyGovernor() {
        epoch.endBlock = _epochEndBlock;
    }
    
    /**
     * @notice set warmup period for new stakers
     * @param _warmupPeriod uint
     */
    function setWarmup( uint _warmupPeriod ) external onlyGovernor() {
        warmupPeriod = _warmupPeriod;
    }
}