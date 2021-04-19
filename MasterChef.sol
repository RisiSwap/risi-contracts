// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/IBEP20.sol";
import "./libs/SafeBEP20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./PeanutToken.sol";

// MasterChef is the master of Peanutanic. He can make Peanutanic and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once PEANUT is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Ownable, ReentrancyGuard {
	using SafeMath for uint256;
	using SafeBEP20 for IBEP20;

	// Info of each user.
	struct UserInfo {
		uint256 amount; // How many LP tokens the user has provided.
		uint256 rewardDebt; // Reward debt. See explanation below.
		//
		// We do some fancy math here. Basically, any point in time, the amount of PEANUTs
		// enpeanutled to a user but is pending to be distributed is:
		//
		//   pending reward = (user.amount * pool.accPeanutPerShare) - user.rewardDebt
		//
		// Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
		//   1. The pool's `accPeanutPerShare` (and `lastRewardBlock`) gets updated.
		//   2. User receives the pending reward sent to his/her address.
		//   3. User's `amount` gets updated.
		//   4. User's `rewardDebt` gets updated.
	}

	// Info of each pool.
	struct PoolInfo {
		IBEP20 lpToken; // Address of LP token contract.
		uint256 allocPoint; // How many allocation points assigned to this pool. PEANUTs to distribute per block.
		uint256 lastRewardBlock; // Last block number that PEANUTs distribution occurs.
		uint256 accPeanutPerShare; // Accumulated PEANUTs per share, times 1e12. See below.
		uint16 depositFeeBP; // Deposit fee in basis points
	}

	// The PEANUT TOKEN!
	PeanutToken public peanut;
	// Deposit Fee address
	address public feeAddress1;
	address public feeAddress2;
	// PEANUT tokens created per block.
	uint256 public peanutPerBlock;
	// Bonus muliplier for early peanut makers.
	uint256 public constant BONUS_MULTIPLIER = 1;

	// Initial emission rate: 1 PEANUT per block.
	uint256 public constant INITIAL_EMISSION_RATE = 1 ether;
	// Minimum emission rate: 0.1 PEANUT per block.
	uint256 public constant MINIMUM_EMISSION_RATE = 100 finney;
	// Reduce emission every 14,400 blocks ~ 12 hours.
	uint256 public constant EMISSION_REDUCTION_PERIOD_BLOCKS = 14400;
	// Emission reduction rate per period in basis points: 3%.
	uint256 public constant EMISSION_REDUCTION_RATE_PER_PERIOD = 300;
	// Last reduction period index
	uint256 public lastReductionPeriodIndex = 0;

	// Info of each pool.
	PoolInfo[] public poolInfo;
	// Info of each user that stakes LP tokens.
	mapping(uint256 => mapping(address => UserInfo)) public userInfo;
	// Total allocation points. Must be the sum of all allocation points in all pools.
	uint256 public totalAllocPoint = 0;
	// The block number when PEANUT mining starts.
	uint256 public startBlock;

	event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
	event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
	event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);

	constructor(
		PeanutToken _peanut,
		uint256 _startBlock,
		address _feeAddress2
	) public {
		peanut = _peanut;
		startBlock = _startBlock;

		feeAddress1 = msg.sender;
		feeAddress2 = _feeAddress2;
		peanutPerBlock = INITIAL_EMISSION_RATE;
	}

	function poolLength() external view returns (uint256) {
		return poolInfo.length;
	}

	// Add a new lp to the pool. Can only be called by the owner.
	// XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
	function add(
		uint256 _allocPoint,
		IBEP20 _lpToken,
		uint16 _depositFeeBP,
		bool _withUpdate
	) public onlyOwner {
		require(_depositFeeBP <= 10000, "add: invalid deposit fee basis points");
		if (_withUpdate) {
			massUpdatePools();
		}
		uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
		totalAllocPoint = totalAllocPoint.add(_allocPoint);
		poolInfo.push(
			PoolInfo({
				lpToken: _lpToken,
				allocPoint: _allocPoint,
				lastRewardBlock: lastRewardBlock,
				accPeanutPerShare: 0,
				depositFeeBP: _depositFeeBP
			})
		);
	}

	// Update the given pool's PEANUT allocation point and deposit fee. Can only be called by the owner.
	function set(
		uint256 _pid,
		uint256 _allocPoint,
		uint16 _depositFeeBP,
		bool _withUpdate
	) public onlyOwner {
		require(_depositFeeBP <= 10000, "set: invalid deposit fee basis points");
		if (_withUpdate) {
			massUpdatePools();
		}
		totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
		poolInfo[_pid].allocPoint = _allocPoint;
		poolInfo[_pid].depositFeeBP = _depositFeeBP;
	}

	// Return reward multiplier over the given _from to _to block.
	function getMultiplier(uint256 _from, uint256 _to) public pure returns (uint256) {
		return _to.sub(_from).mul(BONUS_MULTIPLIER);
	}

	// View function to see pending PEANUTs on frontend.
	function pendingPeanut(uint256 _pid, address _user) external view returns (uint256) {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][_user];
		uint256 accPeanutPerShare = pool.accPeanutPerShare;
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (block.number > pool.lastRewardBlock && lpSupply != 0) {
			uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
			uint256 peanutReward = multiplier.mul(peanutPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
			accPeanutPerShare = accPeanutPerShare.add(peanutReward.mul(1e12).div(lpSupply));
		}
		return user.amount.mul(accPeanutPerShare).div(1e12).sub(user.rewardDebt);
	}

	// Update reward variables for all pools. Be careful of gas spending!
	function massUpdatePools() public {
		uint256 length = poolInfo.length;
		for (uint256 pid = 0; pid < length; ++pid) {
			updatePool(pid);
		}
	}

	// Update reward variables of the given pool to be up-to-date.
	function updatePool(uint256 _pid) public {
		PoolInfo storage pool = poolInfo[_pid];
		if (block.number <= pool.lastRewardBlock) {
			return;
		}
		uint256 lpSupply = pool.lpToken.balanceOf(address(this));
		if (lpSupply == 0 || pool.allocPoint == 0) {
			pool.lastRewardBlock = block.number;
			return;
		}
		uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
		uint256 peanutReward = multiplier.mul(peanutPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
		peanut.mint(address(this), peanutReward);
		pool.accPeanutPerShare = pool.accPeanutPerShare.add(peanutReward.mul(1e12).div(lpSupply));
		pool.lastRewardBlock = block.number;
	}

	// Deposit LP tokens to MasterChef for PEANUT allocation.
	function deposit(uint256 _pid, uint256 _amount) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		updatePool(_pid);
		if (user.amount > 0) {
			uint256 pending = user.amount.mul(pool.accPeanutPerShare).div(1e12).sub(user.rewardDebt);
			if (pending > 0) {
				safePeanutTransfer(msg.sender, pending);
			}
		}
		if (_amount > 0) {
			pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
			if (pool.depositFeeBP > 0) {
				uint256 depositFee = _amount.mul(pool.depositFeeBP).div(10000) / 2;
				pool.lpToken.safeTransfer(feeAddress1, depositFee);
				pool.lpToken.safeTransfer(feeAddress2, depositFee);
				user.amount = user.amount.add(_amount).sub(depositFee);
			} else {
				user.amount = user.amount.add(_amount);
			}
		}
		user.rewardDebt = user.amount.mul(pool.accPeanutPerShare).div(1e12);
		emit Deposit(msg.sender, _pid, _amount);
	}

	// Withdraw LP tokens from MasterChef.
	function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		require(user.amount >= _amount, "withdraw: not good");
		updatePool(_pid);
		uint256 pending = user.amount.mul(pool.accPeanutPerShare).div(1e12).sub(user.rewardDebt);
		if (pending > 0) {
			safePeanutTransfer(msg.sender, pending);
		}
		if (_amount > 0) {
			user.amount = user.amount.sub(_amount);
			pool.lpToken.safeTransfer(address(msg.sender), _amount);
		}
		user.rewardDebt = user.amount.mul(pool.accPeanutPerShare).div(1e12);
		emit Withdraw(msg.sender, _pid, _amount);
	}

	// Withdraw without caring about rewards. EMERGENCY ONLY.
	function emergencyWithdraw(uint256 _pid) public nonReentrant {
		PoolInfo storage pool = poolInfo[_pid];
		UserInfo storage user = userInfo[_pid][msg.sender];
		uint256 amount = user.amount;
		user.amount = 0;
		user.rewardDebt = 0;
		pool.lpToken.safeTransfer(address(msg.sender), amount);
		emit EmergencyWithdraw(msg.sender, _pid, amount);
	}

	// Safe peanut transfer function, just in case if rounding error causes pool to not have enough PEANUTs.
	function safePeanutTransfer(address _to, uint256 _amount) internal {
		uint256 peanutBal = peanut.balanceOf(address(this));
		bool transferSuccess = false;
		if (_amount > peanutBal) {
			transferSuccess = peanut.transfer(_to, peanutBal);
		} else {
			transferSuccess = peanut.transfer(_to, _amount);
		}
		require(transferSuccess, "safePeanutTransfer: Transfer failed");
	}

	function setFeeAddress1(address _feeAddress1) public {
		require(msg.sender == feeAddress1, "setFeeAddress: FORBIDDEN");
		feeAddress1 = _feeAddress1;
	}

	function setFeeAddress2(address _feeAddress2) public {
		require(msg.sender == feeAddress2, "setFeeAddress: FORBIDDEN");
		feeAddress2 = _feeAddress2;
	}

	// Reduce emission rate by 3% every 9,600 blocks ~ 8hours. This function can be called publicly.
	function updateEmissionRate() public {
		require(block.number > startBlock, "updateEmissionRate: Can only be called after mining starts");
		require(peanutPerBlock > MINIMUM_EMISSION_RATE, "updateEmissionRate: Emission rate has reached the minimum threshold");

		uint256 currentIndex = block.number.sub(startBlock).div(EMISSION_REDUCTION_PERIOD_BLOCKS);
		if (currentIndex <= lastReductionPeriodIndex) {
			return;
		}

		uint256 newEmissionRate = peanutPerBlock;
		for (uint256 index = lastReductionPeriodIndex; index < currentIndex; ++index) {
			newEmissionRate = newEmissionRate.mul(1e4 - EMISSION_REDUCTION_RATE_PER_PERIOD).div(1e4);
		}

		newEmissionRate = newEmissionRate < MINIMUM_EMISSION_RATE ? MINIMUM_EMISSION_RATE : newEmissionRate;
		if (newEmissionRate >= peanutPerBlock) {
			return;
		}

		massUpdatePools();
		lastReductionPeriodIndex = currentIndex;
		uint256 previousEmissionRate = peanutPerBlock;
		peanutPerBlock = newEmissionRate;
		emit EmissionRateUpdated(msg.sender, previousEmissionRate, newEmissionRate);
	}

	function setStartBlock(uint256 _startBlock) external {
		require(block.number < startBlock, "It's too late to postpone mining. It has already started");
		startBlock = _startBlock;
	}
}
