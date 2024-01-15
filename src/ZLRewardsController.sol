// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

import {RecoverERC20} from "./utils/RecoverERC20.sol";
import {IZLRewardsController} from "./interfaces/IZLRewardsController.sol";
import {IZeroLocker} from "./interfaces/IZeroLocker.sol";
import {IStreamedVesting} from "./interfaces/IStreamedVesting.sol";
import {IIncentivesController} from "./interfaces/IIncentivesController.sol";

/// @title ChefIncentivesController Contract
/// @author Radiant
/// based on the Sushi MasterChef
///	https://github.com/sushiswap/sushiswap/blob/master/contracts/MasterChef.sol
contract ZLRewardsController is
    IZLRewardsController,
    Initializable,
    PausableUpgradeable,
    OwnableUpgradeable,
    RecoverERC20
{
    using SafeERC20 for IERC20;

    // multiplier for reward calc
    uint256 private constant ACC_REWARD_PRECISION = 1e12;

    // Data about the future reward rates. emissionSchedule stored in chronological order,
    // whenever the duration since the start timestamp exceeds the next timestamp offset a new
    // reward rate is applied.
    EmissionPoint[] public emissionSchedule;

    // If true, keep this new reward rate indefinitely
    // If false, keep this reward rate until the next scheduled block offset, then return to the schedule.
    bool public persistRewardsPerSecond;

    /********************** Emission Info ***********************/

    // Array of tokens for reward
    address[] public registeredTokens;

    // Current reward per second
    uint256 public rewardsPerSecond;

    // last RPS, used during refill after reserve empty
    uint256 public lastRPS;

    // Index in emission schedule which the last rewardsPerSeconds was used
    // only used for scheduled rewards
    uint256 public emissionScheduleIndex;

    // Info of each pool.
    mapping(address => PoolInfo) public poolInfo;
    mapping(address => bool) private validRTokens;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint;

    // token => user => Info of each user that stakes LP tokens.
    mapping(address => mapping(address => UserInfo)) public userInfo;

    // user => base claimable balance
    mapping(address => uint256) public userBaseClaimable;

    // MFD, bounties, AC
    mapping(address => bool) public eligibilityExempt;

    // The block number when reward mining starts.
    uint256 public startTime;

    // Address for PoolConfigurator
    address public poolConfigurator;

    // Amount of deposited rewards
    uint256 public depositedRewards;

    // Amount of accumulated rewards
    uint256 public accountedRewards;

    // Timestamp when all pools updated
    uint256 public lastAllPoolUpdate;

    // MultiFeeDistribution contract
    IStreamedVesting public streamedVesting;

    // locker contract
    IZeroLocker public locker;

    // Info of reward emission end time
    EndingTime public endingTime;

    // Contracts that are authorized to handle r/vdToken actions without triggering elgiibility checks
    mapping(address => bool) public authorizedContracts;

    // Mapping of addresses that are whitelisted to perform
    mapping(address => bool) public whitelist;
    // Flag to quickly enable/disable whitelisting
    bool public whitelistActive;

    // The one and only RDNT token
    address public rdntToken;

    modifier isWhitelisted() {
        if (whitelistActive) {
            if (!whitelist[msg.sender] && msg.sender != address(this))
                revert NotWhitelisted();
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializer
     * @param _poolConfigurator Pool configurator address
     * @param _streamedVesting Vesting contract
     * @param _locker Locker contract
     * @param _rewardsPerSecond RPS
     */
    function initialize(
        address _poolConfigurator,
        IStreamedVesting _streamedVesting,
        IZeroLocker _locker,
        uint256 _rewardsPerSecond,
        address _rdntToken,
        uint256 _endingTimeCadence
    ) public initializer {
        if (_poolConfigurator == address(0)) revert AddressZero();
        if (_rdntToken == address(0)) revert AddressZero();
        if (address(_streamedVesting) == address(0)) revert AddressZero();

        __Ownable_init();
        __Pausable_init();

        poolConfigurator = _poolConfigurator;
        endingTime.updateCadence = _endingTimeCadence;
        streamedVesting = _streamedVesting;
        locker = _locker;
        rdntToken = _rdntToken;
        rewardsPerSecond = _rewardsPerSecond;
        persistRewardsPerSecond = true;
    }

    /**
     * @dev Returns length of reward pools.
     */
    function poolLength() public view returns (uint256) {
        return registeredTokens.length;
    }

    /**
     * @notice Sets incentive controllers for custom token.
     * @param _token for reward pool
     * @param _incentives incentives contract address
     */
    function setOnwardIncentives(
        address _token,
        IIncentivesController _incentives
    ) external onlyOwner {
        PoolInfo storage pool = poolInfo[_token];
        if (pool.lastRewardTime == 0) revert UnknownPool();
        pool.onwardIncentives = _incentives;
        emit OnwardIncentivesUpdated(_token, _incentives);
    }

    /********************** Pool Setup + Admin ***********************/

    /**
     * @dev Starts RDNT emission.
     */
    function start() public onlyOwner {
        if (startTime != 0) revert AlreadyStarted();
        startTime = block.timestamp;
    }

    /**
     * @dev Add a new lp to the pool. Can only be called by the poolConfigurator.
     * @param _token for reward pool
     * @param _allocPoint allocation point of the pool
     */
    function addPool(address _token, uint256 _allocPoint) external {
        if (msg.sender != poolConfigurator) revert NotAllowed();
        if (poolInfo[_token].lastRewardTime != 0) revert PoolExists();
        _updateEmissions();
        totalAllocPoint = totalAllocPoint + _allocPoint;
        registeredTokens.push(_token);
        PoolInfo storage pool = poolInfo[_token];
        pool.allocPoint = _allocPoint;
        pool.lastRewardTime = block.timestamp;
        pool.onwardIncentives = IIncentivesController(address(0));
        validRTokens[_token] = true;
    }

    /**
     * @dev Update the given pool's allocation point. Can only be called by the owner.
     * @param _tokens for reward pools
     * @param _allocPoints allocation points of the pools
     */
    function batchUpdateAllocPoint(
        address[] calldata _tokens,
        uint256[] calldata _allocPoints
    ) external onlyOwner {
        if (_tokens.length != _allocPoints.length) revert ArrayLengthMismatch();
        _massUpdatePools();
        uint256 _totalAllocPoint = totalAllocPoint;
        uint256 length = _tokens.length;
        for (uint256 i; i < length; ) {
            PoolInfo storage pool = poolInfo[_tokens[i]];
            if (pool.lastRewardTime == 0) revert UnknownPool();
            _totalAllocPoint =
                _totalAllocPoint -
                pool.allocPoint +
                _allocPoints[i];
            pool.allocPoint = _allocPoints[i];
            unchecked {
                i++;
            }
        }
        totalAllocPoint = _totalAllocPoint;
        emit BatchAllocPointsUpdated(_tokens, _allocPoints);
    }

    /**
     * @notice Sets the reward per second to be distributed. Can only be called by the owner.
     * @dev Its decimals count is ACC_REWARD_PRECISION
     * @param _rewardsPerSecond The amount of reward to be distributed per second.
     * @param _persist true if RPS is fixed, otherwise RPS is by emission schedule.
     */
    function setRewardsPerSecond(
        uint256 _rewardsPerSecond,
        bool _persist
    ) external onlyOwner {
        _massUpdatePools();
        rewardsPerSecond = _rewardsPerSecond;
        persistRewardsPerSecond = _persist;
        emit RewardsPerSecondUpdated(_rewardsPerSecond, _persist);
    }

    /**
     * @dev Updates RPS.
     */
    function setScheduledRewardsPerSecond() internal {
        if (!persistRewardsPerSecond) {
            uint256 length = emissionSchedule.length;
            uint256 i = emissionScheduleIndex;
            uint128 offset = uint128(block.timestamp - startTime);
            for (
                ;
                i < length && offset >= emissionSchedule[i].startTimeOffset;

            ) {
                unchecked {
                    i++;
                }
            }
            if (i > emissionScheduleIndex) {
                emissionScheduleIndex = i;
                _massUpdatePools();
                rewardsPerSecond = uint256(
                    emissionSchedule[i - 1].rewardsPerSecond
                );
            }
        }
    }

    /**
     * @notice Ensure that the specified time offset hasn't been registered already.
     * @param _startTimeOffset time offset
     * @return true if the specified time offset is already registered
     */
    function _checkDuplicateSchedule(
        uint256 _startTimeOffset
    ) internal view returns (bool) {
        uint256 length = emissionSchedule.length;
        for (uint256 i = 0; i < length; ) {
            if (emissionSchedule[i].startTimeOffset == _startTimeOffset) {
                return true;
            }
            unchecked {
                i++;
            }
        }
        return false;
    }

    /**
     * @notice Updates RDNT emission schedule.
     * @dev This appends the new offsets and RPS.
     * @param _startTimeOffsets Offsets array.
     * @param _rewardsPerSecond RPS array.
     */
    function setEmissionSchedule(
        uint256[] calldata _startTimeOffsets,
        uint256[] calldata _rewardsPerSecond
    ) external onlyOwner {
        uint256 length = _startTimeOffsets.length;
        if (length <= 0 || length != _rewardsPerSecond.length)
            revert ArrayLengthMismatch();

        for (uint256 i = 0; i < length; ) {
            if (i > 0) {
                if (_startTimeOffsets[i - 1] > _startTimeOffsets[i])
                    revert NotAscending();
            }
            if (_startTimeOffsets[i] > type(uint128).max)
                revert ExceedsMaxInt();
            if (_rewardsPerSecond[i] > type(uint128).max)
                revert ExceedsMaxInt();
            if (_checkDuplicateSchedule(_startTimeOffsets[i]))
                revert DuplicateSchedule();

            if (startTime > 0) {
                if (_startTimeOffsets[i] < block.timestamp - startTime)
                    revert InvalidStart();
            }
            emissionSchedule.push(
                EmissionPoint({
                    startTimeOffset: uint128(_startTimeOffsets[i]),
                    rewardsPerSecond: uint128(_rewardsPerSecond[i])
                })
            );
            unchecked {
                i++;
            }
        }
        emit EmissionScheduleAppended(_startTimeOffsets, _rewardsPerSecond);
    }

    /**
     * @notice Recover tokens in this contract. Callable by owner.
     * @param tokenAddress Token address for recover
     * @param tokenAmount Amount to recover
     */
    function recoverERC20(
        address tokenAddress,
        uint256 tokenAmount
    ) external onlyOwner {
        _recoverERC20(tokenAddress, tokenAmount);
    }

    /********************** Pool State Changers ***********************/

    /**
     * @dev Update emission params of CIC.
     */
    function _updateEmissions() internal {
        if (block.timestamp > endRewardTime()) {
            _massUpdatePools();
            lastRPS = rewardsPerSecond;
            rewardsPerSecond = 0;
            return;
        }
        setScheduledRewardsPerSecond();
    }

    /**
     * @dev Update reward variables for all pools.
     */
    function _massUpdatePools() internal {
        uint256 totalAP = totalAllocPoint;
        uint256 length = poolLength();
        for (uint256 i; i < length; ) {
            _updatePool(poolInfo[registeredTokens[i]], totalAP);
            unchecked {
                i++;
            }
        }
        lastAllPoolUpdate = block.timestamp;
    }

    /**
     * @dev Update reward variables of the given pool to be up-to-date.
     * @param pool pool info
     * @param _totalAllocPoint allocation point of the pool
     */
    function _updatePool(
        PoolInfo storage pool,
        uint256 _totalAllocPoint
    ) internal {
        uint256 timestamp = block.timestamp;
        uint256 endReward = endRewardTime();
        if (endReward <= timestamp) {
            timestamp = endReward;
        }
        if (timestamp <= pool.lastRewardTime) {
            return;
        }

        (uint256 reward, uint256 newAccRewardPerShare) = _newRewards(
            pool,
            _totalAllocPoint
        );
        accountedRewards = accountedRewards + reward;
        pool.accRewardPerShare = pool.accRewardPerShare + newAccRewardPerShare;
        pool.lastRewardTime = timestamp;
    }

    /********************** Emission Calc + Transfer ***********************/

    /**
     * @notice Pending rewards of a user.
     * @param _user address for claim
     * @param _tokens array of reward-bearing tokens
     * @return claimable rewards array
     */
    function pendingRewards(
        address _user,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256[] memory claimable = new uint256[](_tokens.length);
        uint256 length = _tokens.length;
        for (uint256 i; i < length; ) {
            address token = _tokens[i];
            PoolInfo storage pool = poolInfo[token];
            UserInfo storage user = userInfo[token][_user];
            uint256 accRewardPerShare = pool.accRewardPerShare;
            if (block.timestamp > pool.lastRewardTime) {
                (, uint256 newAccRewardPerShare) = _newRewards(
                    pool,
                    totalAllocPoint
                );
                accRewardPerShare = accRewardPerShare + newAccRewardPerShare;
            }
            claimable[i] =
                (user.amount * accRewardPerShare) /
                ACC_REWARD_PRECISION -
                user.rewardDebt;
            unchecked {
                i++;
            }
        }
        return claimable;
    }

    /**
     * @notice Claim rewards. They are vested with the vesting contract.
     * @param _user address for claim
     * @param _tokens array of reward-bearing tokens
     */
    function claim(
        address _user,
        address[] memory _tokens
    ) public whenNotPaused {
        _updateEmissions();

        uint256 currentTimestamp = block.timestamp;

        uint256 pending = userBaseClaimable[_user];
        userBaseClaimable[_user] = 0;
        uint256 _totalAllocPoint = totalAllocPoint;
        uint256 length = _tokens.length;
        for (uint256 i; i < length; ) {
            if (!validRTokens[_tokens[i]]) revert InvalidRToken();
            PoolInfo storage pool = poolInfo[_tokens[i]];
            if (pool.lastRewardTime == 0) revert UnknownPool();
            _updatePool(pool, _totalAllocPoint);
            UserInfo storage user = userInfo[_tokens[i]][_user];
            uint256 rewardDebt = (user.amount * pool.accRewardPerShare) /
                ACC_REWARD_PRECISION;
            pending = pending + rewardDebt - user.rewardDebt;
            user.rewardDebt = rewardDebt;
            user.lastClaimTime = currentTimestamp;
            unchecked {
                i++;
            }
        }

        _vestTokens(_user, pending);
    }

    /**
     * @notice Vest tokens to the vesting contract.
     * @param _user address to receive
     * @param _amount to vest
     */
    function _vestTokens(address _user, uint256 _amount) internal {
        if (_amount == 0) revert NothingToVest();
        streamedVesting.createVestFor(_user, _amount);
    }

    /**
     * @notice Updates whether the provided address is authorized to call setEligibilityExempt(), only callable by owner.
     * @param _address address of the user or contract whose authorization level is being changed
     */
    function setContractAuthorization(
        address _address,
        bool _authorize
    ) external onlyOwner {
        if (authorizedContracts[_address] == _authorize)
            revert AuthorizationAlreadySet();
        authorizedContracts[_address] = _authorize;
        emit AuthorizedContractUpdated(_address, _authorize);
    }

    /********************** Eligibility + Disqualification ***********************/

    /**
     * @notice `after` Hook for deposit and borrow update.
     * @dev important! eligible status can be updated here
     * @param _user address
     * @param _balance balance of token
     * @param _totalSupply total supply of the token
     */
    function handleActionAfter(
        address _user,
        uint256 _balance,
        uint256 _totalSupply
    ) external {
        if (!validRTokens[msg.sender] && msg.sender != address(streamedVesting))
            revert NotRTokenOrMfd();

        if (_user == address(streamedVesting)) return;

        _handleActionAfterForToken(msg.sender, _user, _balance, _totalSupply);
    }

    /**
     * @notice `after` Hook for deposit and borrow update.
     * @dev important! eligible status can be updated here
     * @param _token address
     * @param _user address
     * @param _balance new amount
     * @param _totalSupply total supply of the token
     */
    function _handleActionAfterForToken(
        address _token,
        address _user,
        uint256 _balance,
        uint256 _totalSupply
    ) internal {
        PoolInfo storage pool = poolInfo[_token];
        if (pool.lastRewardTime == 0) revert UnknownPool();
        // Although we would want the pools to be as up to date as possible when users
        // transfer rTokens or dTokens, updating all pools on every r-/d-Token interaction would be too gas intensive.
        // _updateEmissions();
        _updatePool(pool, totalAllocPoint);
        UserInfo storage user = userInfo[_token][_user];
        uint256 amount = user.amount;
        uint256 accRewardPerShare = pool.accRewardPerShare;
        if (amount != 0) {
            uint256 pending = (amount * accRewardPerShare) /
                ACC_REWARD_PRECISION -
                user.rewardDebt;
            if (pending != 0) {
                userBaseClaimable[_user] = userBaseClaimable[_user] + pending;
            }
        }
        pool.totalSupply = pool.totalSupply - user.amount;
        user.amount = _balance;
        user.rewardDebt = (_balance * accRewardPerShare) / ACC_REWARD_PRECISION;
        pool.totalSupply = pool.totalSupply + _balance;
        if (pool.onwardIncentives != IIncentivesController(address(0))) {
            pool.onwardIncentives.handleAction(
                _token,
                _user,
                _balance,
                _totalSupply
            );
        }

        emit BalanceUpdated(_token, _user, _balance, _totalSupply);
    }

    /**
     * @notice `before` Hook for deposit and borrow update.
     * @param _user address
     */
    function handleActionBefore(address _user) external {}

    /**
     * @notice Hook for lock update.
     * @dev Called by the locking contracts before locking or unlocking happens
     * @param _user address
     */
    function beforeLockUpdate(address _user) external {}

    /**
     * @notice Hook for lock update.
     * @dev Called by the locking contracts after locking or unlocking happens
     * @param _user address
     */
    function afterLockUpdate(address _user) external {
        _updateRegisteredBalance(_user);
    }

    /**
     * @notice Update balance if there are any unregistered.
     * @param _user address of the user whose balances will be updated
     */
    function _updateRegisteredBalance(address _user) internal {
        uint256 length = poolLength();
        for (uint256 i; i < length; ) {
            uint256 newBal = IERC20(registeredTokens[i]).balanceOf(_user);
            uint256 registeredBal = userInfo[registeredTokens[i]][_user].amount;
            if (newBal != 0 && newBal != registeredBal) {
                _handleActionAfterForToken(
                    registeredTokens[i],
                    _user,
                    newBal,
                    poolInfo[registeredTokens[i]].totalSupply +
                        newBal -
                        registeredBal
                );
            }
            unchecked {
                i++;
            }
        }
    }

    /********************** Eligibility + Disqualification ***********************/

    /**
     * @dev Returns true if `_user` has some reward eligible tokens.
     * @param _user address of recipient
     */
    function hasEligibleDeposits(
        address _user
    ) public view returns (bool hasDeposits) {
        uint256 length = poolLength();
        for (uint256 i; i < length; ) {
            if (userInfo[registeredTokens[i]][_user].amount != 0) {
                hasDeposits = true;
                break;
            }
            unchecked {
                i++;
            }
        }
    }

    /**
     * @dev Send RNDT rewards to user.
     * @param _user address of recipient
     * @param _amount of RDNT
     */
    function _sendRadiant(address _user, uint256 _amount) internal {
        if (_amount == 0) {
            return;
        }

        address rdntToken_ = rdntToken;
        uint256 chefReserve = IERC20(rdntToken_).balanceOf(address(this));
        if (_amount > chefReserve) {
            revert OutOfRewards();
        } else {
            IERC20(rdntToken_).safeTransfer(_user, _amount);
        }
    }

    /********************** RDNT Reserve Management ***********************/

    /**
     * @notice Ending reward distribution time.
     */
    function endRewardTime() public returns (uint256) {
        if (
            endingTime.lastUpdatedTime + endingTime.updateCadence >
            block.timestamp
        ) {
            return endingTime.estimatedTime;
        }

        uint256 unclaimedRewards = availableRewards();
        uint256 extra = 0;
        uint256 length = poolLength();
        for (uint256 i; i < length; ) {
            PoolInfo storage pool = poolInfo[registeredTokens[i]];

            if (pool.lastRewardTime > lastAllPoolUpdate) {
                extra +=
                    ((pool.lastRewardTime - lastAllPoolUpdate) *
                        pool.allocPoint *
                        rewardsPerSecond) /
                    totalAllocPoint;
            }
            unchecked {
                i++;
            }
        }
        endingTime.lastUpdatedTime = block.timestamp;

        if (rewardsPerSecond == 0) {
            endingTime.estimatedTime = type(uint256).max;
            return type(uint256).max;
        } else {
            uint256 newEndTime = (unclaimedRewards + extra) /
                rewardsPerSecond +
                lastAllPoolUpdate;
            endingTime.estimatedTime = newEndTime;
            return newEndTime;
        }
    }

    /**
     * @notice Updates cadence duration of ending time.
     * @dev Only callable by owner.
     * @param _lapse new cadence
     */
    function setEndingTimeUpdateCadence(uint256 _lapse) external onlyOwner {
        if (_lapse > 1 weeks) revert CadenceTooLong();
        endingTime.updateCadence = _lapse;
        emit EndingTimeUpdateCadence(_lapse);
    }

    /**
     * @notice Add new rewards.
     * @dev Only callable by owner.
     * @param _amount new deposit amount
     */
    function registerRewardDeposit(uint256 _amount) external onlyOwner {
        depositedRewards = depositedRewards + _amount;
        _massUpdatePools();
        if (rewardsPerSecond == 0 && lastRPS > 0) {
            rewardsPerSecond = lastRPS;
        }
        emit RewardDeposit(_amount);
    }

    /**
     * @notice Available reward amount for future distribution.
     * @dev This value is equal to `depositedRewards` - `accountedRewards`.
     * @return amount available
     */
    function availableRewards() internal view returns (uint256 amount) {
        return depositedRewards - accountedRewards;
    }

    /**
     * @notice Claim rewards entitled to all registered tokens.
     * @param _user address of the user
     */
    function claimAll(address _user) external {
        claim(_user, registeredTokens);
    }

    /**
     * @notice Sum of all pending RDNT rewards.
     * @param _user address of the user
     * @return pending reward amount
     */
    function allPendingRewards(
        address _user
    ) public view returns (uint256 pending) {
        pending = userBaseClaimable[_user];
        uint256[] memory claimable = pendingRewards(_user, registeredTokens);
        uint256 length = claimable.length;
        for (uint256 i; i < length; ) {
            pending += claimable[i];
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Pause the claim operations.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpause the claim operations.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Returns new rewards since last reward time.
     * @param pool pool info
     * @param _totalAllocPoint allocation point of the pool
     */
    function _newRewards(
        PoolInfo memory pool,
        uint256 _totalAllocPoint
    ) internal view returns (uint256 newReward, uint256 newAccRewardPerShare) {
        uint256 lpSupply = pool.totalSupply;
        if (lpSupply > 0) {
            uint256 duration = block.timestamp - pool.lastRewardTime;
            uint256 rawReward = duration * rewardsPerSecond;

            uint256 rewards = availableRewards();
            if (rewards < rawReward) {
                rawReward = rewards;
            }
            newReward = (rawReward * pool.allocPoint) / _totalAllocPoint;
            newAccRewardPerShare =
                (newReward * ACC_REWARD_PRECISION) /
                lpSupply;
        }
    }

    /**
     * @notice Add new address to whitelist.
     * @param user address
     * @param status for whitelist
     */
    function setAddressWLstatus(address user, bool status) external onlyOwner {
        whitelist[user] = status;
    }

    /**
     * @notice Toggle whitelist to be either active or inactive
     */
    function toggleWhitelist() external onlyOwner {
        whitelistActive = !whitelistActive;
    }
}
