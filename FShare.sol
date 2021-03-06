// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "./owner/Operator.sol";

/*
  ____ ____    ___   ____  ____ __  __      ___  ___  ____  __ ______  ___  __
 ||    || \\  // \\    // ||    ||\ ||     //   // \\ || \\ || | || | // \\ ||
 ||==  ||_// ((   ))  //  ||==  ||\\||    ((    ||=|| ||_// ||   ||   ||=|| ||
 ||    || \\  \\_//  //__ ||___ || \||     \\__ || || ||    ||   ||   || || ||__|

    https://frozen.capital
*/
contract FShare is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 63,000 fSHAREs
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 60000 ether;
    uint256 public constant DEV_FUND_POOL_ALLOCATION = 3000 ether;
    uint256 public constant COMMUNITY_FUND_POOL_ALLOCATION = 0 ether;

    uint256 public constant VESTING_DURATION = 90 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public communityFundRewardRate;
    uint256 public devFundRewardRate;

    address public communityFund;
    address public devFund;

    uint256 public communityFundLastClaimed;
    uint256 public devFundLastClaimed;

    bool public rewardPoolDistributed = false;

    constructor(uint256 _startTime, address _communityFund, address _devFund) public ERC20("FSHARE", "FSHARE") {
        _mint(msg.sender, 1 ether); // mint 1 FROST Share for initial pools deployment

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_communityFund != address(0), "Address cannot be 0");
        communityFund = _communityFund;
    }

    function setTreasuryFund(address _communityFund) external {
        require(msg.sender == devFund, "!dev");
        communityFund = _communityFund;
    }

    function setDevFund(address _devFund) external {
        require(msg.sender == devFund, "!dev");
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedTreasuryFund() public view returns (uint256 _pending) {
        return 0;
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        return 0;
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedTreasuryFund();
        if (_pending > 0 && communityFund != address(0)) {
            _mint(communityFund, _pending);
            communityFundLastClaimed = block.timestamp;
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
            devFundLastClaimed = block.timestamp;
        }
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _farmingIncentiveFund) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_farmingIncentiveFund != address(0), "!_farmingIncentiveFund");
        rewardPoolDistributed = true;
        _mint(_farmingIncentiveFund, FARMING_POOL_REWARD_ALLOCATION);
        _mint(devFund, DEV_FUND_POOL_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
