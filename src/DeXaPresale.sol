// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "./interfaces/IDeXaPresale.sol";
import "./interfaces/IRegistration.sol";

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "forge-std/console2.sol";

contract DeXaPresale is ReentrancyGuard, Ownable, IDeXaPresale {
    uint8 public constant referralDeep = 6;

    uint32 public releaseMonth;

    address public deXa;

    address public coreTeamAddress;
    address public companyAddress;

    address public ntr;
    address public busd;
    address public register;

    uint256 private constant MONTH = 86400 * 30;
    // uint256 private constant MONTH = 60 * 5; // for test

    uint256 private constant MULTIPLER = 125000000000000000;
    uint256 public ntrAmountForCoreTeam;
    uint256 public busdAmountForCoreTeam;
    uint256 public ntrAmountForOwner;
    uint256 public busdAmountForOwner;
    uint256 public percentForCoreTeam;

    mapping(address => uint256) public refRewardByBUSD;
    mapping(address => uint256) public refRewardByNTR;
    mapping(address => uint256) public claimableTokens;

    uint8[referralDeep] public referralRate;

    RoundInfo[3] public roundInfo;

    modifier onlyRegisterUser() {
        require(
            IRegistration(register).isRegistered(msg.sender),
            "No registered."
        );
        _;
    }

    constructor(
        address _deXa,
        address _ntr,
        address _busd,
        address _register,
        address _coreTeam,
        address _company
    ) Ownable() {
        deXa = _deXa;
        ntr = _ntr;
        busd = _busd;
        register = _register;
        coreTeamAddress = _coreTeam;
        companyAddress = _company;
        percentForCoreTeam = 10000;
        releaseMonth = 8;
    }

    function tokenPurchaseWithBUSD(
        uint256 _busdAmount
    ) public onlyRegisterUser {
        int8 _round = getRound();
        require(
            _round == 0 || _round == 1 || _round == 2,
            "Not started any Round."
        );

        require(!hasSoldOut(uint8(_round), true), "Dexa is already sold out!");

        RoundInfo storage info = roundInfo[uint8(_round)];
        require(info.busdEnabled, "Not enable to purchase with BUSD");

        require(
            _busdAmount >= info.minContributionForBusd,
            "Min contribution criteria not met"
        );
        require(
            _busdAmount <= info.maxContributionForBusd,
            "Max contribution criteria not met"
        );

        IERC20(busd).transferFrom(msg.sender, address(this), _busdAmount);

        info.busdRaised = info.busdRaised + _busdAmount;

        info.contributions[msg.sender].contributedBusdAmount += _busdAmount;
        if (info.contributions[msg.sender].purchaseTimeForBusd == 0) {
            info.contributions[msg.sender].purchaseTimeForBusd = block
                .timestamp;
        }

        uint256 busdForCoreTeam = (_busdAmount * percentForCoreTeam) /
            MULTIPLER;

        busdAmountForCoreTeam += busdForCoreTeam;

        uint256 busdForOwner = _busdAmount - busdForCoreTeam;

        uint256 tokenAmount = (_busdAmount * 1e18) / info.priceForBusd; //made change of multiplier
        console2.log("tokenAmount: ", tokenAmount);

        info
            .contributions[msg.sender]
            .totalClaimableTokenAmountForBusd += tokenAmount;

        address[] memory referrers = IRegistration(register)
            .getReferrerAddresses(msg.sender);
        for (uint8 i = 0; i < referralDeep; i++) {
            if (referrers[i] == address(0)) {
                break;
            }
            uint256 bonus = (_busdAmount * referralRate[i]) / MULTIPLER;
            refRewardByBUSD[referrers[i]] += bonus;
            busdForOwner -= bonus;
            emit SetRefRewardBUSD(
                referrers[i],
                msg.sender,
                uint8(i + 1),
                uint8(_round),
                bonus
            );
        }

        busdAmountForOwner += busdForOwner;

        emit TokenPurchaseWithBUSD(
            msg.sender,
            uint8(_round),
            _busdAmount,
            busdForOwner
        );
    }

    function setRoundInfoForBusd(
        uint8 _index,
        uint256 _priceForBusd,
        uint256 _startTime,
        uint256 _endTime,
        uint8 _lockMonths,
        uint256 _maxDexaAmountToSell,
        uint256 _minContributionForBusd,
        uint256 _maxContributionForBusd
    ) public onlyOwner {
        RoundInfo storage info = roundInfo[_index];
        info.priceForBusd = _priceForBusd;
        info.priceForNtr = 0;
        info.startTime = _startTime;
        info.endTime = _endTime;
        info.lockMonths = _lockMonths;
        info.maxDexaAmountToSell = _maxDexaAmountToSell;
        info.busdEnabled = true;
        info.ntrEnabled = false;
        info.minContributionForBusd = _minContributionForBusd;
        info.minContributionForNtr = 0;
        info.maxContributionForBusd = _maxContributionForBusd;
        info.maxContributionForNtr = 0;
    }

    function claimTokensFromBusd(
        uint8 _round
    ) external nonReentrant onlyRegisterUser {
        ContributionInfo storage cInfo = roundInfo[_round].contributions[
            msg.sender
        ];
        require(cInfo.contributedBusdAmount > 0, "Nothing to claim");

        require(
            (block.timestamp - cInfo.purchaseTimeForBusd) / MONTH >=
                roundInfo[_round].lockMonths,
            "Locked"
        );

        uint256 tokenAmount = getClaimableTokenAmountFromBusd(
            _round,
            msg.sender
        );
        cInfo.claimedTokenAmountForBusd += tokenAmount;

        cInfo.lastClaimedTimeForBusd = block.timestamp;

        IERC20(deXa).transfer(msg.sender, tokenAmount);

        emit TokenClaim(msg.sender, _round, tokenAmount);
    }

    // function claimPrebookTokens() external override nonReentrant {
    //     uint256 amount = claimableTokens[msg.sender];
    //     if (amount < 0) {
    //         revert BookingNotFound();
    //     }

    //     IERC20(deXa).transfer(msg.sender, amount);
    //     delete claimableTokens[msg.sender];
    // }

    function getClaimableTokenAmountFromBusd(
        uint8 _round,
        address _user
    ) public view returns (uint256) {
        RoundInfo storage info = roundInfo[_round];
        ContributionInfo memory contribution = info.contributions[_user];

        if (
            (block.timestamp - contribution.purchaseTimeForBusd) / MONTH >
            info.lockMonths
        ) {
            uint256 months = (block.timestamp -
                contribution.purchaseTimeForBusd) /
                MONTH -
                info.lockMonths;

            if (months > releaseMonth) months = releaseMonth;

            uint256 tokenAmount = (months *
                contribution.totalClaimableTokenAmountForBusd) /
                releaseMonth -
                contribution.claimedTokenAmountForBusd;

            // if (
            //     (info.lockMonths * MONTH) + (releaseMonth * MONTH) <=
            //     block.timestamp
            // ) {
            //     contribution.claimedTokenAmountForBusd
            // }

            return tokenAmount;
        } else {
            return 0;
        }
    }

    // function getClaimableTokenAmountFromBusd(
    //     uint8 _round,
    //     address _user
    // ) public view returns (uint256 tokenAmount) {
    //     RoundInfo storage info = roundInfo[_round];
    //     ContributionInfo memory cInfo = info.contributions[_user];

    //     if (info.lockMonths <= block.timestamp) {
    //         uint256 timeDiff = block.timestamp - cInfo.lastClaimedTimeForBusd;
    //         tokenAmount = cInfo.totalClaimableTokenAmountForBusd * MULTIPLER;
    //         tokenAmount = timeDiff * tokenAmount;
    //         if (
    //             releaseMonth * MONTH + info.lockMonths * MONTH <=
    //             block.timestamp
    //         ) {
    //             uint256 remainingAmount = cInfo
    //                 .totalClaimableTokenAmountForBusd -
    //                 cInfo.claimedTokenAmountForBusd;
    //             tokenAmount += remainingAmount;
    //         }
    //     } else {
    //         return 0;
    //     }
    // }

    function allowanceToUser(
        address _user,
        uint256 _busdAmount,
        uint256 _round
    ) external override onlyOwner {
        if (_user == address(0) || _busdAmount < 0) {
            revert InvalidInputValue();
        }

        require(
            _round == 0 || _round == 1 || _round == 2,
            "Not started any Round."
        );

        require(!hasSoldOut(uint8(_round), true), "Dexa is already sold out!");

        RoundInfo storage info = roundInfo[uint8(_round)];
        require(info.busdEnabled, "Not enable to purchase with BUSD");

        require(
            _busdAmount >= info.minContributionForBusd,
            "Min contribution criteria not met"
        );
        require(
            _busdAmount <= info.maxContributionForBusd,
            "Max contribution criteria not met"
        );

        claimableTokens[_user] += _busdAmount;

        info.busdRaised = info.busdRaised + _busdAmount;

        info.contributions[msg.sender].contributedBusdAmount += _busdAmount;
        if (info.contributions[_user].purchaseTimeForBusd == 0) {
            info.contributions[_user].purchaseTimeForBusd = block.timestamp;
        }

        uint256 busdForCoreTeam = (_busdAmount * percentForCoreTeam) /
            MULTIPLER;

        busdAmountForCoreTeam += busdForCoreTeam;

        uint256 busdForOwner = _busdAmount - busdForCoreTeam;

        uint256 tokenAmount = (_busdAmount * MULTIPLER) / info.priceForBusd;

        info
            .contributions[_user]
            .totalClaimableTokenAmountForBusd += tokenAmount;

        address[] memory referrers = IRegistration(register)
            .getReferrerAddresses(_user);
        for (uint8 i = 0; i < referralDeep; i++) {
            if (referrers[i] == address(0)) {
                break;
            }
            uint256 bonus = (_busdAmount * referralRate[i]) / MULTIPLER;
            refRewardByBUSD[referrers[i]] += bonus;
            busdForOwner -= bonus;
            emit SetRefRewardBUSD(
                referrers[i],
                _user,
                uint8(i + 1),
                uint8(_round),
                bonus
            );
        }

        busdAmountForOwner += busdForOwner;

        emit TokenPurchaseWithBUSD(
            _user,
            uint8(_round),
            _busdAmount,
            busdForOwner
        );
    }

    function batchAllowanceToUsers(
        address[] memory _users,
        uint256[] memory _busdAmounts,
        uint256[] memory _rounds
    ) external onlyOwner {
        if (_users.length != _busdAmounts.length) {
            revert InvalidInputLength();
        }
        uint256 len = _users.length;
        for (uint256 i = 0; i < len; i++) {
            if (_users[i] == address(0) || _busdAmounts[i] < 0) {
                revert InvalidInputValue();
            }
            require(
                _rounds[i] == 0 || _rounds[i] == 1 || _rounds[i] == 2,
                "Not started any Round."
            );

            require(
                !hasSoldOut(uint8(_rounds[i]), true),
                "Dexa is already sold out!"
            );

            RoundInfo storage info = roundInfo[uint8(_rounds[i])];
            require(info.busdEnabled, "Not enable to purchase with BUSD");

            require(
                _busdAmounts[i] >= info.minContributionForBusd,
                "Min contribution criteria not met"
            );
            require(
                _busdAmounts[i] <= info.maxContributionForBusd,
                "Max contribution criteria not met"
            );

            claimableTokens[_users[i]] += _busdAmounts[i];

            info.busdRaised = info.busdRaised + _busdAmounts[i];

            info
                .contributions[_users[i]]
                .contributedBusdAmount += _busdAmounts[i];
            if (info.contributions[msg.sender].purchaseTimeForBusd == 0) {
                info.contributions[msg.sender].purchaseTimeForBusd = block
                    .timestamp;
            }

            uint256 busdForCoreTeam = (_busdAmounts[i] * percentForCoreTeam) /
                MULTIPLER;

            busdAmountForCoreTeam += busdForCoreTeam;

            uint256 busdForOwner = _busdAmounts[i] - busdForCoreTeam;

            uint256 tokenAmount = (_busdAmounts[i] * MULTIPLER) /
                info.priceForBusd;

            info
                .contributions[_users[i]]
                .totalClaimableTokenAmountForBusd += tokenAmount;

            address[] memory referrers = IRegistration(register)
                .getReferrerAddresses(_users[i]);
            for (uint8 i = 0; i < referralDeep; i++) {
                if (referrers[i] == address(0)) {
                    break;
                }
                uint256 bonus = (_busdAmounts[i] * referralRate[i]) / MULTIPLER;
                refRewardByBUSD[referrers[i]] += bonus;
                busdForOwner -= bonus;
                emit SetRefRewardBUSD(
                    referrers[i],
                    _users[i],
                    uint8(i + 1),
                    uint8(_rounds[i]),
                    bonus
                );
            }

            busdAmountForOwner += busdForOwner;

            emit TokenPurchaseWithBUSD(
                _users[i],
                uint8(_rounds[i]),
                _busdAmounts[i],
                busdForOwner
            );
        }
    }

    function getRound() public view returns (int8) {
        int8 ret = -1;
        uint256 nowTime = block.timestamp;

        if (nowTime < roundInfo[0].startTime) {
            ret = -1; // any round is not started
        } else if (
            nowTime >= roundInfo[0].startTime && nowTime < roundInfo[0].endTime
        ) {
            ret = 0; // in round 1
        } else if (
            nowTime >= roundInfo[0].endTime && nowTime < roundInfo[1].startTime
        ) {
            ret = -2; // round 2 is not started
        } else if (
            nowTime >= roundInfo[1].startTime && nowTime < roundInfo[1].endTime
        ) {
            ret = 1; // in round 2
        } else if (
            nowTime >= roundInfo[1].endTime && nowTime < roundInfo[2].startTime
        ) {
            ret = -3; // round 3 is not started
        } else if (
            nowTime >= roundInfo[2].startTime && nowTime < roundInfo[2].endTime
        ) {
            ret = 2; // in round 3
        } else if (nowTime >= roundInfo[2].endTime) {
            ret = -4; // all round is ended
        }
        return ret;
    }

    function hasSoldOut(uint8 _round, bool _isBusd) public view returns (bool) {
        RoundInfo storage info = roundInfo[_round];
        uint256 dexaAmount = 0;
        if (_isBusd)
            dexaAmount = (info.busdRaised * MULTIPLER) / info.priceForBusd;
        else dexaAmount = (info.ntrRaised * MULTIPLER) / info.priceForNtr;

        if (dexaAmount > info.maxDexaAmountToSell) return true;
        else return false;
    }
}
