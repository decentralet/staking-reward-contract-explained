pragma solidity ^0.5.16;

import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";
import "./utils/RewardsDistributionRecipient.sol";
import "./utils/Pausable.sol";

// https://docs.synthetix.io/contracts/source/contracts/stakingrewards
contract StakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard, Pausable {
    using SafeMath for uint256; 
    /** This smart contract was rewritten before version 0.8.0 so overflow and underflow must be placed into consideration and this library (SafeMath) and making 
     * it available for use to all uint256 dataTypes
      */
    using SafeERC20 for IERC20;
    /**
     * SafeERC20 library would help in transfer ERC20 token even if during implemention, the functions therein does not return a boolean [here by preventing error]
     */

    /* ========== STATE VARIABLES ========== */

    IERC20 public rewardsToken; // This is the address of the token that would be dispersed as reward
    IERC20 public stakingToken; // This is the address of the token that would be staked into this contract 
    uint256 public periodFinish = 0; // This is a block.timestamp when the reward distrubtion would be ending 
    uint256 public rewardRate = 0; // This is going to be the (total-reward / duration staking would last)
    uint256 public rewardsDuration = 60; // This is the reward duration 
    uint256 public lastUpdateTime; // This variable holds when(block.timestamp) a stake or withdraw action takes place on this contract 
    uint256 public rewardPerTokenStored; // This is a very important variable, it holds the reward per token 

    mapping(address => uint256) public userRewardPerTokenPaid; // This is the specific reward per token of a user 
    mapping(address => uint256) public rewards; // This mapping stores the reward a users has accumulated with time 

    uint256 private _totalSupply; // This is the number of tokens that has been staked or the number of share minted out
    mapping(address => uint256) private _balances; // This mapping holds the number of token a user has staked 

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _owner,
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public Owned(_owner) {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution; // This is the address that can change the reward distrubtion and some other state variable in this contract
    }

    /* ========== VIEWS ========== */

    /// @notice this function would return the number of tokens that has been staked 
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    /// @notice this function would return the number of tokens a user staked 
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    /// @notice this function would return when the staking is going to be over is the current block.timestamp is less than that time else  it would just return the block.timestamp
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    /// 
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) external nonReentrant notPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice this function would send to the user the accumulated reward 
    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    /// this function would send to the user the accumulated rewards on staking and also send to the user the tokens they staked 
    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) { // this means the inital stakig duration has ended and you want to re-init the staking process
            rewardRate = reward.div(rewardsDuration); 
        } else { // because the inital staking period has not ended, the rewardRate needs to take account the previous rate before upadting the rate
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw the staking token");
        IERC20(tokenAddress).safeTransfer(owner, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            block.timestamp > periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}