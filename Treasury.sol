// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./lib/Babylonian.sol";
import "./owner/Operator.sol";
import "./utils/ContractGuard.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/IOracle.sol";
import "./interfaces/ILodge.sol";

/*
  ____ ____    ___   ____  ____ __  __      ___  ___  ____  __ ______  ___  __
 ||    || \\  // \\    // ||    ||\ ||     //   // \\ || \\ || | || | // \\ ||
 ||==  ||_// ((   ))  //  ||==  ||\\||    ((    ||=|| ||_// ||   ||   ||=|| ||
 ||    || \\  \\_//  //__ ||___ || \||     \\__ || || ||    ||   ||   || || ||__|

    https://frozen.capital
*/
contract Treasury is ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========= CONSTANT VARIABLES ======== */

    uint256 public constant PERIOD = 6 hours;

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    // epoch
    uint256 public startTime;
    uint256 public epoch = 0;
    uint256 public epochSupplyContractionLeft = 0;

    // exclusions from total supply
        address[] public excludedFromTotalSupply = [
            address(0x14E29AC5CB859BeC03D78C12F7FB6Da828b2A250), // FrostGenesisPool
            address(0x88F258515aD026FD039fAAa186EED75c9e3B8C27) // FrostRewardPool
        ];

    // core components
    address public frost;
    address public fbond;
    address public fshare;

    address public lodge;
    address public frostOracle;

    // price
    uint256 public frostPriceOne;
    uint256 public frostPriceCeiling;

    uint256 public seigniorageSaved;

    uint256[] public supplyTiers;
    uint256[] public maxExpansionTiers;

    uint256 public maxSupplyExpansionPercent;
    uint256 public bondDepletionFloorPercent;
    uint256 public seigniorageExpansionFloorPercent;
    uint256 public maxSupplyContractionPercent;
    uint256 public maxDebtRatioPercent;

    // 28 first epochs (1 week) with 4.5% expansion regardless of FROST price
    uint256 public bootstrapEpochs;
    uint256 public bootstrapSupplyExpansionPercent;

    /* =================== Added variables =================== */
    uint256 public previousEpochFrostPrice;
    uint256 public maxDiscountRate; // when purchasing bond
    uint256 public maxPremiumRate; // when redeeming bond
    uint256 public discountPercent;
    uint256 public premiumThreshold;
    uint256 public premiumPercent;
    uint256 public mintingFactorForPayingDebt; // print extra FROST during debt phase

    address public daoFund;
    uint256 public daoFundSharedPercent;

    address public devFund;
    uint256 public devFundSharedPercent;

    /* =================== Events =================== */

    event Initialized(address indexed executor, uint256 at);
    event BurnedBonds(address indexed from, uint256 bondAmount);
    event RedeemedBonds(address indexed from, uint256 frostAmount, uint256 bondAmount);
    event BoughfBonds(address indexed from, uint256 frostAmount, uint256 bondAmount);
    event TreasuryFunded(uint256 timestamp, uint256 seigniorage);
    event LodgeFunded(uint256 timestamp, uint256 seigniorage);
    event DaoFundFunded(uint256 timestamp, uint256 seigniorage);
    event DevFundFunded(uint256 timestamp, uint256 seigniorage);

    /* =================== Modifier =================== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Treasury: caller is not the operator");
        _;
    }

    modifier checkCondition {
        require(now >= startTime, "Treasury: not started yet");

        _;
    }

    modifier checkEpoch {
        require(now >= nextEpochPoint(), "Treasury: not opened yet");

        _;

        epoch = epoch.add(1);
        epochSupplyContractionLeft = (getFrostPrice() > frostPriceCeiling) ? 0 : getFrostCirculatingSupply().mul(maxSupplyContractionPercent).div(10000);
    }

    modifier checkOperator {
        require(
            IBasisAsset(frost).operator() == address(this) &&
                IBasisAsset(fbond).operator() == address(this) &&
                IBasisAsset(fshare).operator() == address(this) &&
                Operator(lodge).operator() == address(this),
            "Treasury: need more permission"
        );

        _;
    }

    modifier notInitialized {
        require(!initialized, "Treasury: already initialized");

        _;
    }

    /* ========== VIEW FUNCTIONS ========== */

    function isInitialized() public view returns (bool) {
        return initialized;
    }

    // epoch
    function nextEpochPoint() public view returns (uint256) {
        return startTime.add(epoch.mul(PERIOD));
    }

    // oracle
    function getFrostPrice() public view returns (uint256 frostPrice) {
        try IOracle(frostOracle).consult(frost, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult FROST price from the oracle");
        }
    }

    function getFrostUpdatedPrice() public view returns (uint256 _frostPrice) {
        try IOracle(frostOracle).twap(frost, 1e18) returns (uint144 price) {
            return uint256(price);
        } catch {
            revert("Treasury: failed to consult FROST price from the oracle");
        }
    }

    // budget
    function getReserve() public view returns (uint256) {
        return seigniorageSaved;
    }

    function getBurnableFrostLeft() public view returns (uint256 _burnableFrostLeft) {
        uint256 _frostPrice = getFrostPrice();
        if (_frostPrice <= frostPriceOne) {
            uint256 _frostSupply = getFrostCirculatingSupply();
            uint256 _bondMaxSupply = _frostSupply.mul(maxDebtRatioPercent).div(10000);
            uint256 _bondSupply = IERC20(fbond).totalSupply();
            if (_bondMaxSupply > _bondSupply) {
                uint256 _maxMintableBond = _bondMaxSupply.sub(_bondSupply);
                uint256 _maxBurnableFrost = _maxMintableBond.mul(_frostPrice).div(1e16);
                _burnableFrostLeft = Math.min(epochSupplyContractionLeft, _maxBurnableFrost);
            }
        }
    }

    function getRedeemableBonds() public view returns (uint256 _redeemableBonds) {
        uint256 _frostPrice = getFrostPrice();
        if (_frostPrice > frostPriceCeiling) {
            uint256 _totalFrost = IERC20(frost).balanceOf(address(this));
            uint256 _rate = gefBondPremiumRate();
            if (_rate > 0) {
                _redeemableBonds = _totalFrost.mul(1e16).div(_rate);
            }
        }
    }

    function gefBondDiscountRate() public view returns (uint256 _rate) {
        uint256 _frostPrice = getFrostPrice();
        if (_frostPrice <= frostPriceOne) {
            if (discountPercent == 0) {
                // no discount
                _rate = frostPriceOne;
            } else {
                uint256 _bondAmount = frostPriceOne.mul(1e18).div(_frostPrice); // to burn 1 FROST
                uint256 _discountAmount = _bondAmount.sub(frostPriceOne).mul(discountPercent).div(10000);
                _rate = frostPriceOne.add(_discountAmount);
                if (maxDiscountRate > 0 && _rate > maxDiscountRate) {
                    _rate = maxDiscountRate;
                }
            }
        }
    }

    function gefBondPremiumRate() public view returns (uint256 _rate) {
        uint256 _frostPrice = getFrostPrice();
        if (_frostPrice > frostPriceCeiling) {
            uint256 _frostPricePremiumThreshold = frostPriceOne.mul(premiumThreshold).div(100);
            if (_frostPrice >= _frostPricePremiumThreshold) {
                //Price > 1.10
                uint256 _premiumAmount = _frostPrice.sub(frostPriceOne).mul(premiumPercent).div(10000);
                _rate = frostPriceOne.add(_premiumAmount);
                if (maxPremiumRate > 0 && _rate > maxPremiumRate) {
                    _rate = maxPremiumRate;
                }
            } else {
                // no premium bonus
                _rate = frostPriceOne;
            }
        }
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        address _frost,
        address _fbond,
        address _fshare,
        address _frostOracle,
        address _lodge,
        uint256 _startTime
    ) public notInitialized {
        frost = _frost;
        fbond = _fbond;
        fshare = _fshare;
        frostOracle = _frostOracle;
        lodge = _lodge;
        startTime = _startTime;

        frostPriceOne = 10**16; // PEG of 100 frost per AVAX
        frostPriceCeiling = frostPriceOne.mul(101).div(100);

        // Dynamic max expansion percent
        supplyTiers = [0 ether, 500000 ether, 1000000 ether, 1500000 ether, 2000000 ether, 5000000 ether, 10000000 ether, 20000000 ether, 50000000 ether];
        maxExpansionTiers = [450, 400, 350, 300, 250, 200, 150, 125, 100];

        maxSupplyExpansionPercent = 400; // Upto 4.0% supply for expansion

        bondDepletionFloorPercent = 10000; // 100% of Bond supply for depletion floor
        seigniorageExpansionFloorPercent = 3500; // At least 35% of expansion reserved for lodge
        maxSupplyContractionPercent = 300; // Upto 3.0% supply for contraction (to burn FROST and mint fBOND)
        maxDebtRatioPercent = 3500; // Upto 35% supply of fBOND to purchase

        premiumThreshold = 110;
        premiumPercent = 7000;

        // First 28 epochs with 4.5% expansion
        bootstrapEpochs = 28;
        bootstrapSupplyExpansionPercent = 450;

        // set seigniorageSaved to it's balance
        seigniorageSaved = IERC20(frost).balanceOf(address(this));

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setLodge(address _lodge) external onlyOperator {
        lodge = _lodge;
    }

    function setFrostOracle(address _frostOracle) external onlyOperator {
        frostOracle = _frostOracle;
    }

    function setFrostPriceCeiling(uint256 _frostPriceCeiling) external onlyOperator {
        require(_frostPriceCeiling >= frostPriceOne && _frostPriceCeiling <= frostPriceOne.mul(120).div(100), "out of range"); // [$1.0, $1.2]
        frostPriceCeiling = _frostPriceCeiling;
    }

    function setMaxSupplyExpansionPercents(uint256 _maxSupplyExpansionPercent) external onlyOperator {
        require(_maxSupplyExpansionPercent >= 10 && _maxSupplyExpansionPercent <= 1000, "_maxSupplyExpansionPercent: out of range"); // [0.1%, 10%]
        maxSupplyExpansionPercent = _maxSupplyExpansionPercent;
    }

    function setSupplyTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        if (_index > 0) {
            require(_value > supplyTiers[_index - 1]);
        }
        if (_index < 8) {
            require(_value < supplyTiers[_index + 1]);
        }
        supplyTiers[_index] = _value;
        return true;
    }

    function setMaxExpansionTiersEntry(uint8 _index, uint256 _value) external onlyOperator returns (bool) {
        require(_index >= 0, "Index has to be higher than 0");
        require(_index < 9, "Index has to be lower than count of tiers");
        require(_value >= 10 && _value <= 1000, "_value: out of range"); // [0.1%, 10%]
        maxExpansionTiers[_index] = _value;
        return true;
    }

    function sefBondDepletionFloorPercent(uint256 _bondDepletionFloorPercent) external onlyOperator {
        require(_bondDepletionFloorPercent >= 500 && _bondDepletionFloorPercent <= 10000, "out of range"); // [5%, 100%]
        bondDepletionFloorPercent = _bondDepletionFloorPercent;
    }

    function setMaxSupplyContractionPercent(uint256 _maxSupplyContractionPercent) external onlyOperator {
        require(_maxSupplyContractionPercent >= 100 && _maxSupplyContractionPercent <= 1500, "out of range"); // [0.1%, 15%]
        maxSupplyContractionPercent = _maxSupplyContractionPercent;
    }

    function setMaxDebtRatioPercent(uint256 _maxDebtRatioPercent) external onlyOperator {
        require(_maxDebtRatioPercent >= 1000 && _maxDebtRatioPercent <= 10000, "out of range"); // [10%, 100%]
        maxDebtRatioPercent = _maxDebtRatioPercent;
    }

    function setBootstrap(uint256 _bootstrapEpochs, uint256 _bootstrapSupplyExpansionPercent) external onlyOperator {
        require(_bootstrapEpochs <= 120, "_bootstrapEpochs: out of range"); // <= 1 month
        require(_bootstrapSupplyExpansionPercent >= 100 && _bootstrapSupplyExpansionPercent <= 1000, "_bootstrapSupplyExpansionPercent: out of range"); // [1%, 10%]
        bootstrapEpochs = _bootstrapEpochs;
        bootstrapSupplyExpansionPercent = _bootstrapSupplyExpansionPercent;
    }

    function setExtraFunds(
        address _daoFund,
        uint256 _daoFundSharedPercent,
        address _devFund,
        uint256 _devFundSharedPercent
    ) external onlyOperator {
        require(_daoFund != address(0), "zero");
        require(_daoFundSharedPercent <= 3000, "out of range"); // <= 30%
        require(_devFund != address(0), "zero");
        require(_devFundSharedPercent <= 1000, "out of range"); // <= 10%
        daoFund = _daoFund;
        daoFundSharedPercent = _daoFundSharedPercent;
        devFund = _devFund;
        devFundSharedPercent = _devFundSharedPercent;
    }

    function setMaxDiscountRate(uint256 _maxDiscountRate) external onlyOperator {
        maxDiscountRate = _maxDiscountRate;
    }

    function setMaxPremiumRate(uint256 _maxPremiumRate) external onlyOperator {
        maxPremiumRate = _maxPremiumRate;
    }

    function setDiscountPercent(uint256 _discountPercent) external onlyOperator {
        require(_discountPercent <= 20000, "_discountPercent is over 200%");
        discountPercent = _discountPercent;
    }

    function setPremiumThreshold(uint256 _premiumThreshold) external onlyOperator {
        require(_premiumThreshold >= frostPriceCeiling, "_premiumThreshold exceeds frostPriceCeiling");
        require(_premiumThreshold <= 150, "_premiumThreshold is higher than 1.5");
        premiumThreshold = _premiumThreshold;
    }

    function setPremiumPercent(uint256 _premiumPercent) external onlyOperator {
        require(_premiumPercent <= 20000, "_premiumPercent is over 200%");
        premiumPercent = _premiumPercent;
    }

    function setMintingFactorForPayingDebt(uint256 _mintingFactorForPayingDebt) external onlyOperator {
        require(_mintingFactorForPayingDebt >= 10000 && _mintingFactorForPayingDebt <= 20000, "_mintingFactorForPayingDebt: out of range"); // [100%, 200%]
        mintingFactorForPayingDebt = _mintingFactorForPayingDebt;
    }

    /* ========== MUTABLE FUNCTIONS ========== */

    function _updateFrostPrice() internal {
        try IOracle(frostOracle).update() {} catch {}
    }

    function getFrostCirculatingSupply() public view returns (uint256) {
        IERC20 frostErc20 = IERC20(frost);
        uint256 totalSupply = frostErc20.totalSupply();
        uint256 balanceExcluded = 0;
        for (uint8 entryId = 0; entryId < excludedFromTotalSupply.length; ++entryId) {
            balanceExcluded = balanceExcluded.add(frostErc20.balanceOf(excludedFromTotalSupply[entryId]));
        }
        return totalSupply.sub(balanceExcluded);
    }

    function buyBonds(uint256 _frostAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_frostAmount > 0, "Treasury: cannot purchase bonds with zero amount");

        uint256 frostPrice = getFrostPrice();
        require(frostPrice == targetPrice, "Treasury: FROST price moved");
        require(
            frostPrice < frostPriceOne, // price < $1
            "Treasury: frostPrice not eligible for bond purchase"
        );

        require(_frostAmount <= epochSupplyContractionLeft, "Treasury: not enough bond left to purchase");

        uint256 _rate = gefBondDiscountRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _bondAmount = _frostAmount.mul(_rate).div(1e16);
        uint256 frostSupply = getFrostCirculatingSupply();
        uint256 newBondSupply = IERC20(fbond).totalSupply().add(_bondAmount);
        require(newBondSupply <= frostSupply.mul(maxDebtRatioPercent).div(10000), "over max debt ratio");

        IBasisAsset(frost).burnFrom(msg.sender, _frostAmount);
        IBasisAsset(fbond).mint(msg.sender, _bondAmount);

        epochSupplyContractionLeft = epochSupplyContractionLeft.sub(_frostAmount);
        _updateFrostPrice();

        emit BoughfBonds(msg.sender, _frostAmount, _bondAmount);
    }

    function redeemBonds(uint256 _bondAmount, uint256 targetPrice) external onlyOneBlock checkCondition checkOperator {
        require(_bondAmount > 0, "Treasury: cannot redeem bonds with zero amount");

        uint256 frostPrice = getFrostPrice();
        require(frostPrice == targetPrice, "Treasury: FROST price moved");
        require(
            frostPrice > frostPriceCeiling, // price > $1.01
            "Treasury: frostPrice not eligible for bond purchase"
        );

        uint256 _rate = gefBondPremiumRate();
        require(_rate > 0, "Treasury: invalid bond rate");

        uint256 _frostAmount = _bondAmount.mul(_rate).div(1e16);
        require(IERC20(frost).balanceOf(address(this)) >= _frostAmount, "Treasury: treasury has no more budget");

        seigniorageSaved = seigniorageSaved.sub(Math.min(seigniorageSaved, _frostAmount));

        IBasisAsset(fbond).burnFrom(msg.sender, _bondAmount);
        IERC20(frost).safeTransfer(msg.sender, _frostAmount);

        _updateFrostPrice();

        emit RedeemedBonds(msg.sender, _frostAmount, _bondAmount);
    }

    function _sendToLodge(uint256 _amount) internal {
        IBasisAsset(frost).mint(address(this), _amount);

        uint256 _daoFundSharedAmount = 0;
        if (daoFundSharedPercent > 0) {
            _daoFundSharedAmount = _amount.mul(daoFundSharedPercent).div(10000);
            IERC20(frost).transfer(daoFund, _daoFundSharedAmount);
            emit DaoFundFunded(now, _daoFundSharedAmount);
        }

        uint256 _devFundSharedAmount = 0;
        if (devFundSharedPercent > 0) {
            _devFundSharedAmount = _amount.mul(devFundSharedPercent).div(10000);
            IERC20(frost).transfer(devFund, _devFundSharedAmount);
            emit DevFundFunded(now, _devFundSharedAmount);
        }

        _amount = _amount.sub(_daoFundSharedAmount).sub(_devFundSharedAmount);

        IERC20(frost).safeApprove(lodge, 0);
        IERC20(frost).safeApprove(lodge, _amount);
        ILodge(lodge).allocateSeigniorage(_amount);
        emit LodgeFunded(now, _amount);
    }

    function _calculateMaxSupplyExpansionPercent(uint256 _frostSupply) internal returns (uint256) {
        for (uint8 tierId = 8; tierId >= 0; --tierId) {
            if (_frostSupply >= supplyTiers[tierId]) {
                maxSupplyExpansionPercent = maxExpansionTiers[tierId];
                break;
            }
        }
        return maxSupplyExpansionPercent;
    }

    function allocateSeigniorage() external onlyOneBlock checkCondition checkEpoch checkOperator {
        _updateFrostPrice();
        previousEpochFrostPrice = getFrostPrice();
        uint256 frostSupply = getFrostCirculatingSupply().sub(seigniorageSaved);
        if (epoch < bootstrapEpochs) {
            // 28 first epochs with 4.5% expansion
            _sendToLodge(frostSupply.mul(bootstrapSupplyExpansionPercent).div(10000));
        } else {
            if (previousEpochFrostPrice > frostPriceCeiling) {
                // Expansion ($FROST Price > 1 $AVAX): there is some seigniorage to be allocated
                uint256 bondSupply = IERC20(fbond).totalSupply();
                uint256 _percentage = previousEpochFrostPrice.sub(frostPriceOne);
                uint256 _savedForBond;
                uint256 _savedForLodge;
                uint256 _mse = _calculateMaxSupplyExpansionPercent(frostSupply).mul(1e14);
                if (_percentage > _mse) {
                    _percentage = _mse;
                }
                if (seigniorageSaved >= bondSupply.mul(bondDepletionFloorPercent).div(10000)) {
                    // saved enough to pay debt, mint as usual rate
                    _savedForLodge = frostSupply.mul(_percentage).div(1e16);
                } else {
                    // have not saved enough to pay debt, mint more
                    uint256 _seigniorage = frostSupply.mul(_percentage).div(1e16);
                    _savedForLodge = _seigniorage.mul(seigniorageExpansionFloorPercent).div(10000);
                    _savedForBond = _seigniorage.sub(_savedForLodge);
                    if (mintingFactorForPayingDebt > 0) {
                        _savedForBond = _savedForBond.mul(mintingFactorForPayingDebt).div(10000);
                    }
                }
                if (_savedForLodge > 0) {
                    _sendToLodge(_savedForLodge);
                }
                if (_savedForBond > 0) {
                    seigniorageSaved = seigniorageSaved.add(_savedForBond);
                    IBasisAsset(frost).mint(address(this), _savedForBond);
                    emit TreasuryFunded(now, _savedForBond);
                }
            }
        }
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(frost), "frost");
        require(address(_token) != address(fbond), "bond");
        require(address(_token) != address(fshare), "share");
        _token.safeTransfer(_to, _amount);
    }

    function lodgeSetOperator(address _operator) external onlyOperator {
        ILodge(lodge).setOperator(_operator);
    }

    function lodgeSetLockUp(uint256 _withdrawLockupEpochs, uint256 _rewardLockupEpochs) external onlyOperator {
        ILodge(lodge).setLockUp(_withdrawLockupEpochs, _rewardLockupEpochs);
    }

    function lodgeAllocateSeigniorage(uint256 amount) external onlyOperator {
        ILodge(lodge).allocateSeigniorage(amount);
    }

    function lodgeGovernanceRecoverUnsupported(
        address _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        ILodge(lodge).governanceRecoverUnsupported(_token, _amount, _to);
    }
}
