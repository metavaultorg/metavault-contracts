// SPDX-License-Identifier: MIT
pragma solidity ^0.7.5;

pragma abicoder v2;

import "../shared/interfaces/IAggregatorV3Interface.sol";
import "../shared/interfaces/ITreasury.sol";
import "../shared/interfaces/IStaking.sol";
import "../shared/interfaces/IStakingHelper.sol";
import "../shared/types/MetaVaultAC.sol";
import "../shared/libraries/SafeMath.sol";
import "../shared/libraries/SafeERC20.sol";
import "../shared/libraries/FixedPoint.sol";

interface IBondDepository {
    struct Bond {
        uint256 payout; // MVD remaining to be paid
        uint256 vesting; // Blocks left to vest
        uint256 lastBlock; // Last interaction
        uint256 pricePaid; // In DAI, for front end viewing
    }

    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 vestingTerm; // in blocks
        uint256 minimumPrice; // vs principle value , 4 decimals 0.15 = 1500
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }

    function name() external view returns (string memory);

    function percentVestedFor(address _depositor) external view returns (uint256 percentVested_);

    function pendingPayoutFor(address _depositor) external view returns (uint256 pendingPayout_);

    function bondPrice() external view returns (uint256);

    function bondPriceInUSD() external view returns (uint256);

    function maxPayout() external view returns (uint256);

    function standardizedDebtRatio() external view returns (uint256);

    function terms() external view returns (Terms memory);

    function totalDebt() external view returns (uint256);

    function totalPrinciple() external view returns (uint256);

    function bondInfo(address _depositor) external view returns (Bond memory _info);
}

interface IStakeBondDepository {
    struct Terms {
        uint256 controlVariable; // scaling variable for price
        uint256 vestingTerm; // in blocks
        uint256 minimumPrice; // vs principle value , 4 decimals 0.15 = 1500
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }

    function name() external view returns (string memory);

    function percentVestedFor(address _depositor) external view returns (uint256 percentVested_);

    function pendingPayoutFor(address _depositor) external view returns (uint256 pendingPayout_);

    function bondPrice() external view returns (uint256);

    function bondPriceInUSD() external view returns (uint256);

    function maxPayout() external view returns (uint256);

    function standardizedDebtRatio() external view returns (uint256);

    function terms() external view returns (Terms memory);

    function totalDebt() external view returns (uint256);

    function totalPrinciple() external view returns (uint256);

    function bondInfo(address _depositor)
        external
        view
        returns (
            uint256 payout,
            uint256 vesting,
            uint256 lastBlock,
            uint256 pricePaid
        );
}

contract BondAggregator is MetaVaultAC {
    struct BondTerms {
        uint256 controlVariable; // scaling variable for price
        uint256 vestingTerm; // in blocks
        uint256 minimumPrice; // vs principle value , 4 decimals 0.15 = 1500
        uint256 maxPayout; // in thousandths of a %. i.e. 500 = 0.5%
        uint256 fee; // as % of bond payout, in hundreths. ( 500 = 5% = 0.05 for every 1 paid)
        uint256 maxDebt; // 9 decimal debt ratio, max % total supply created as debt
    }
    struct GlobalBondData {
        string Name;
        address Contract;
        BondAggregator.BondTerms BondTerms;
        uint256 MaxPayout;
        uint256 StandardizedDebtRatio;
        uint256 TotalDebt;
        uint256 BondPriceInUSD;
        uint256 TotalPrinciple;
    }
    struct BondInfo {
        uint256 Payout;
        uint256 Vesting;
        uint256 LastBlock;
        uint256 PricePaid;
    }
    struct UserBondData {
        address Contract;
        string Name;
        BondAggregator.BondInfo Info;
        uint256 PercentVested;
        uint256 PendingPayout;
    }

    address[] public Bonds_11;
    address[] public Bonds_44;

    constructor(address _authority) MetaVaultAC(IMetaVaultAuthority(_authority)) {}

    function globalBondData() public view returns (GlobalBondData[] memory) {
        GlobalBondData[] memory _data = new GlobalBondData[]((Bonds_11.length + Bonds_44.length));

        uint256 index = 0;

        for (uint256 i = 0; i < Bonds_11.length; i++) {
            IBondDepository bond = IBondDepository(Bonds_11[i]);

            IBondDepository.Terms memory terms = bond.terms();

            _data[index] = GlobalBondData({
                Name: bond.name(),
                Contract: Bonds_11[i],
                BondTerms: BondAggregator.BondTerms({
                    controlVariable: terms.controlVariable,
                    vestingTerm: terms.vestingTerm,
                    minimumPrice: terms.minimumPrice,
                    maxPayout: terms.maxPayout,
                    fee: terms.fee,
                    maxDebt: terms.maxDebt
                }),
                MaxPayout: bond.maxPayout(),
                StandardizedDebtRatio: bond.standardizedDebtRatio(),
                TotalDebt: bond.totalDebt(),
                BondPriceInUSD: bond.bondPriceInUSD(),
                TotalPrinciple: bond.totalPrinciple()
            });

            index++;
        }

        for (uint256 i = 0; i < Bonds_44.length; i++) {
            IStakeBondDepository bond = IStakeBondDepository(Bonds_44[i]);

            IStakeBondDepository.Terms memory terms = bond.terms();

            _data[index] = GlobalBondData({
                Name: bond.name(),
                Contract: Bonds_44[i],
                BondTerms: BondAggregator.BondTerms({
                    controlVariable: terms.controlVariable,
                    vestingTerm: terms.vestingTerm,
                    minimumPrice: terms.minimumPrice,
                    maxPayout: terms.maxPayout,
                    fee: terms.fee,
                    maxDebt: terms.maxDebt
                }),
                MaxPayout: bond.maxPayout(),
                StandardizedDebtRatio: bond.standardizedDebtRatio(),
                TotalDebt: bond.totalDebt(),
                BondPriceInUSD: bond.bondPriceInUSD(),
                TotalPrinciple: bond.totalPrinciple()
            });

            index++;
        }

        return _data;
    }

    function perUserBondData(address _depositor) public view returns (UserBondData[] memory) {
        UserBondData[] memory _data = new UserBondData[]((Bonds_11.length + Bonds_44.length));

        uint256 index = 0;

        for (uint256 i = 0; i < Bonds_11.length; i++) {
            IBondDepository bond = IBondDepository(Bonds_11[i]);

            IBondDepository.Bond memory info = bond.bondInfo(_depositor);

            _data[index] = UserBondData({
                Contract: Bonds_11[i],
                Name: bond.name(),
                Info: BondInfo({Payout: info.payout, Vesting: info.vesting, LastBlock: info.lastBlock, PricePaid: info.pricePaid}),
                PercentVested: bond.percentVestedFor(_depositor),
                PendingPayout: bond.pendingPayoutFor(_depositor)
            });
            index++;
        }

        for (uint256 i = 0; i < Bonds_44.length; i++) {
            IStakeBondDepository bond = IStakeBondDepository(Bonds_44[i]);

            (uint256 payout, uint256 vesting, uint256 lastBlock, uint256 pricePaid) = bond.bondInfo(_depositor);

            _data[index] = UserBondData({
                Contract: Bonds_44[i],
                Name: bond.name(),
                Info: BondInfo({Payout: payout, Vesting: vesting, LastBlock: lastBlock, PricePaid: pricePaid}),
                PercentVested: bond.percentVestedFor(_depositor),
                PendingPayout: bond.pendingPayoutFor(_depositor)
            });
            index++;
        }

        return _data;
    }

    function add11BondContracts(address[] memory _contracts) external onlyPolicy {
        for (uint256 i = 0; i < _contracts.length; i++) {
            add11BondContract(_contracts[i]);
        }
    }

    function add11BondContract(address _contract) internal onlyPolicy {
        require(_contract != address(0));

        for (uint256 i = 0; i < Bonds_11.length; i++) {
            if (Bonds_11[i] == _contract) {
                return;
            }
        }

        Bonds_11.push(_contract);
    }

    function add44BondContracts(address[] memory _contracts) external onlyPolicy {
        for (uint256 i = 0; i < _contracts.length; i++) {
            add44BondContract(_contracts[i]);
        }
    }

    function add44BondContract(address _contract) internal onlyPolicy {
        require(_contract != address(0));

        for (uint256 i = 0; i < Bonds_44.length; i++) {
            if (Bonds_44[i] == _contract) {
                return;
            }
        }

        Bonds_44.push(_contract);
    }

    function remove11BondContract(address _contract) external onlyPolicy {
        require(_contract != address(0));

        for (uint256 i = 0; i < Bonds_11.length; i++) {
            if (Bonds_11[i] == _contract) {
                for (uint256 j = i; j < Bonds_11.length - 1; j++) {
                    Bonds_11[j] = Bonds_11[j + 1];
                }

                Bonds_11.pop();
            }
        }
    }

    function remove44BondContract(address _contract) external onlyPolicy {
        require(_contract != address(0));

        for (uint256 i = 0; i < Bonds_44.length; i++) {
            if (Bonds_44[i] == _contract) {
                for (uint256 j = i; j < Bonds_44.length - 1; j++) {
                    Bonds_44[j] = Bonds_44[j + 1];
                }

                Bonds_44.pop();
            }
        }
    }
}
