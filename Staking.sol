// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract Staking is EIP712, Ownable {
    /**
     * @dev Enum representing the different threshold bonus levels.
     */
    enum ThresholdBonus {
        None,
        Silver,
        Gold,
        Diamond        
    }

    /**
     * @dev Enum representing the different timelock bonus durations.
     */
    enum TimelockBonus {
        None,
        Short,
        Long
    }

    /**
     * @dev Struct representing a user's stake.
     * @param amount The amount of tokens staked.
     * @param rewardDebt The user's reward debt.
     * @param depositTime The timestamp of the deposit.
     * @param secondsLocked The duration for which the tokens are locked.
     * @param thresholdBonus The threshold bonus level.
     * @param timelockBonus The timelock bonus level.
     * @param canEdit A flag indicating whether the stake can be edited by the owner.
     */
    struct Stake {
        uint256 amount;         
        uint256 rewardDebt;  
        uint256 depositTime;
        uint256 secondsLocked;
        ThresholdBonus thresholdBonus;
        TimelockBonus timelockBonus;
        bool canEdit;
    }

    /**
     * @dev Struct representing a deposit message.
     * @param amount The amount of tokens to be deposited.
     * @param secondsLocked The duration for which the tokens are locked.
     * @param timeSigned The timestamp of the signature.
     * @param salt The salt used for the signature.
     * @param thresholdBonus The threshold bonus level.
     * @param timelockBonus The timelock bonus level.
     */
    struct DepositMessage {
        uint256 amount;         
        uint256 secondsLocked;
        uint256 timeSigned;
        uint256 salt;
        ThresholdBonus thresholdBonus;
        TimelockBonus timelockBonus;
    }

    /**
     * @dev Struct representing a withdraw message.
     * @param wallet The address of the wallet initiating the withdrawal.
     * @param amount The amount of tokens to withdraw.
     * @param id The ID of the stake to withdraw from.
     * @param timeSigned The timestamp of the signature.
     * @param salt The salt used for the signature.
     * @param thresholdBonus The threshold bonus level.
     */
    struct WithdrawMessage {
        address wallet;
        uint256 amount;         
        uint256 id;
        uint256 timeSigned;
        uint256 salt;
        ThresholdBonus thresholdBonus;
    }

    /**
     * @dev Struct representing pending rewards.
     * @param isLocked A flag indicating whether the tokens are still locked.
     * @param amount The amount of pending rewards.
     */
    struct Pending {
        bool isLocked;
        uint256 amount;         
    }

    IERC20 public depositToken;  // Token used for staking
    IERC20 public rewardToken;   // Token used for rewards

    uint256 public startBlock;               // Block at which rewards start
    uint256 public rewardTokenPerBlock;      // Number of reward tokens distributed per block
    uint256 lastUpdateBlock;                 // Last block number when accRewardTokenPerShare were calculated
    uint256 accRewardTokenPerShare;          // Accumulated reward tokens per share

    address public signer;                   // Address used for signature verification
    address public tokenCustodian;           // Address holding the reward tokens

    bool public isEmergency;                 // Emergency flag
    bool public isPaused;                    // Pause flag

    mapping (address => Stake[]) userStakes; // Mapping of user stakes
    mapping(ThresholdBonus => uint) public thresholdBonuses; // Mapping of threshold bonuses
    mapping(TimelockBonus => uint) public timelockBonuses;   // Mapping of timelock bonuses
    mapping(bytes32 => bool) public usedSignatures;   // Mapping of used signatures


    event Deposit(address indexed user, uint256 amount, uint secondsLocked);
    event Withdraw(address indexed user, uint256 stakeId, uint256 amount);
    event Claim(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);

    bytes32 constant DEPOSIT_MESSAGE_TYPEHASH = keccak256("DepositMessage(uint256 amount,uint256 secondsLocked,uint256 timeSigned,uint256 salt,uint8 thresholdBonus,uint8 timelockBonus)");

    bytes32 constant WITHDRAW_MESSAGE_TYPEHASH = keccak256("WithdrawMessage(address wallet,uint256 amount,uint256 id,uint256 timeSigned,uint256 salt,uint8 thresholdBonus)");  
    //bytes32 constant WITHDRAW_MESSAGE_TYPEHASH = keccak256("WithdrawMessage(address wallet,uint256 amount,uint256 id,uint8 thresholdBonus");  

    /**
     * @dev Initializes the staking contract with the given parameters.
     * @param _depositTokenAddress The address of the token to be deposited.
     * @param _rewardTokenAddress The address of the token to be rewarded.
     * @param _signer The address used for signature verification.
     * @param _tokenCustodian The address holding the reward tokens.
     * @param _rewardTokenPerBlock The number of reward tokens distributed per block.
     * @param _startBlock The block at which rewards start.
     * @param _silver The bonus percentage for the Silver threshold.
     * @param _gold The bonus percentage for the Gold threshold.
     * @param _diamond The bonus percentage for the Diamond threshold.
     * @param _short The bonus percentage for the Short timelock.
     * @param _long The bonus percentage for the Long timelock.
     */
    constructor(
        address _depositTokenAddress,
        address _rewardTokenAddress,
        address _signer,
        address _tokenCustodian,
        uint256 _rewardTokenPerBlock,
        uint256 _startBlock,
        uint _silver, 
        uint _gold ,
        uint _diamond, 
        uint _short, 
        uint _long
    ) EIP712("LEARNStaking", "1") Ownable(msg.sender) {
        depositToken = IERC20(_depositTokenAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        signer = _signer;
        tokenCustodian = _tokenCustodian;
        rewardTokenPerBlock = _rewardTokenPerBlock;
        startBlock = _startBlock;
        thresholdBonuses[ThresholdBonus.Silver] = _silver;
        thresholdBonuses[ThresholdBonus.Gold] = _gold;
        thresholdBonuses[ThresholdBonus.Diamond] = _diamond;
        timelockBonuses[TimelockBonus.Short] = _short;
        timelockBonuses[TimelockBonus.Long] = _long;
    }

    /**
     * @dev Modifier to ensure the contract is not in an emergency state.
     */
    modifier noEmergency() {
        require(!isEmergency, "Emergency");
        _;
    }

    /**
     * @dev Modifier to ensure the contract is not paused.
     */
    modifier noPause() {
        require(!isPaused, "Paused");
        _;
    }

    /**
     * @dev Allows a user to deposit tokens for staking.
     * @param _amount The amount of tokens to deposit.
     * @param _secondsLocked The duration for which the tokens will be locked.
     * @param _thresholdBonus The threshold bonus level.
     * @param _timelockBonus The timelock bonus level.
     * @param _signedMessage The signed message for validation.
     */
    function deposit(
        uint256 _amount, 
        uint256 _secondsLocked, 
        uint256 _timeSigned,
        uint256 _salt,
        uint8 _thresholdBonus, 
        uint8 _timelockBonus, 
        bytes memory _signedMessage
    ) public noEmergency noPause {    
        require(_amount > 0, "No 0 token deposits");   
        require(_timeSigned + 600 > block.timestamp, "Signature expired");   
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DEPOSIT_MESSAGE_TYPEHASH, 
                    _amount,
                    _secondsLocked, 
                    _timeSigned,
                    _salt,
                    _thresholdBonus,
                    _timelockBonus
                )
            )
        );
        address _signer = ECDSA.recover(digest, _signedMessage);
        require(_signer == signer, "Invalid signature");
        require(!usedSignatures[digest], "Signature already used");

        update();

        depositToken.transferFrom(address(msg.sender), address(this), _amount);
        
        Stake[] storage stakes = userStakes[msg.sender];

        require(stakes.length < 10, 'Max 10 stakes per wallet.');

        // On first deposit, create a 0th stake for unlocked deposits 
        if(stakes.length == 0) {
            Stake memory zerothStake = Stake(0, 0, block.timestamp, 0, ThresholdBonus.None, TimelockBonus.None, false);
            stakes.push(zerothStake);
        }

        // If unlocked deposit add _amount to 0th stake, else create new stake
        uint rewardDebt = _getRewardDebt(_amount);
        if(_secondsLocked == 0) {
            stakes[0].amount += _amount;
            stakes[0].rewardDebt = rewardDebt;
            stakes[0].thresholdBonus = ThresholdBonus(_thresholdBonus);
        } else {
            Stake memory stake = Stake(_amount, rewardDebt, block.timestamp, _secondsLocked, ThresholdBonus(_thresholdBonus), TimelockBonus(_timelockBonus), false);
            stakes.push(stake);
        }

        emit Deposit(msg.sender, _amount, _secondsLocked);
    }

    /**
     * @dev Allows a user to withdraw staked tokens.
     * @param _id The ID of the stake to withdraw from.
     * @param _amount The amount of tokens to withdraw.
     * @param _thresholdBonus The threshold bonus level.
     * @param _signedMessage The signed message for validation.
     */
    function withdraw(
        uint256 _id, 
        uint256 _amount,
        uint256 _timeSigned,
        uint256 _salt, 
        uint8 _thresholdBonus,
        bytes memory _signedMessage
    ) public  noEmergency noPause {
        require(_amount != 0, "Can't withdraw 0");
        require(_timeSigned + 600 > block.timestamp, "Signature expired");   
        Stake storage stake = userStakes[msg.sender][_id];

        require(block.timestamp >= stake.depositTime + stake.secondsLocked, "Deposit locked");
        require(stake.amount >= _amount, "Withdraw amount too high");
        
        claim(); 
        stake.amount -= _amount;

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    WITHDRAW_MESSAGE_TYPEHASH, 
                    msg.sender,
                    _amount, 
                    _id,
                    _timeSigned,
                    _salt,
                    _thresholdBonus
                )
            )
        );

        address _signer = ECDSA.recover(digest, _signedMessage);
        require(_signer == signer, "Invalid signature");
        require(!usedSignatures[digest], "Signature already used");

        // Allow for withdraw even if signer is offline. No funds stuck.
        // Any ThresholdBonus issues can be fixed with setEditStake().
        stake.thresholdBonus = (_signer == signer)? ThresholdBonus(_thresholdBonus) : ThresholdBonus.None;
        depositToken.transfer(address(msg.sender), _amount);
  
        emit Withdraw(msg.sender, _id, _amount);
    }

    /**
     * @dev Allows a user to claim their unlocked pending rewards.
     */
    function claim() public noEmergency noPause {
        Stake[] storage stakes = userStakes[msg.sender];
        update();

        uint256 totalRewards = 0;

        for(uint8 i = 0; i < stakes.length; i++){
            totalRewards += _calculateAndClaimReward(stakes, i);
        }

        if(totalRewards > 0){
            rewardToken.transferFrom(tokenCustodian, msg.sender, totalRewards);
            emit Claim(msg.sender, totalRewards);
        }
    }

    /**
     * @dev Allows a user to call claim on a specific stake id.
     */
    function claimById(uint8 _id) public noEmergency noPause {
        Stake[] storage stakes = userStakes[msg.sender];
        update();

        uint256 totalRewards = _calculateAndClaimReward(stakes, _id);

        if(totalRewards > 0){
            rewardToken.transferFrom(tokenCustodian, msg.sender, totalRewards);
            emit Claim(msg.sender, totalRewards);
        }
    }

    /**
     * @dev Calculates the pending rewards for a specific stake and updates reward debt.
     */
    function _calculateAndClaimReward(Stake[] storage stakes, uint8 _id) internal returns (uint256) {
        Stake storage stake = stakes[_id];
        uint256 amount = stake.amount;
        uint256 oldRewardDebt = stake.rewardDebt;
        bool islocked = block.timestamp < stake.depositTime + stake.secondsLocked; 
        uint newRewardDebt = _getRewardDebt(amount);

        if (amount > 0 && !islocked ) {
            uint256 _pending = newRewardDebt - oldRewardDebt;
            uint256 bonus = timelockBonuses[stake.timelockBonus] + thresholdBonuses[stake.thresholdBonus];
            if(_pending > 0) {
                stake.rewardDebt = newRewardDebt;
                return _pending + bonus * _pending / 100;
            }
        }

        return 0;
    }

    /**
     * @dev Allows a user to withdraw all staked tokens without caring about rewards. This function is intended for emergency use only.
     */
    function emergencyWithdraw() public {
        require(isEmergency, "Admin has not declared emergency");

        Stake[] storage stakes = userStakes[msg.sender];
        update();

        uint totalDeposits = 0;
        for(uint8 i = 0; i < stakes.length; i++){
            totalDeposits += stakes[i].amount;
            stakes[i].amount = 0;
            stakes[i].rewardDebt = 0;
        }

        depositToken.transfer(address(msg.sender), totalDeposits);
        emit EmergencyWithdraw(msg.sender, totalDeposits);
    }

    /**
     * @dev Returns the pending rewards for a specific stake by its ID.
     * @param _user The address of the user.
     * @param _id The ID of the stake.
     * @return The pending rewards and whether the tokens are locked.
     */
    function pendingById(address _user, uint8 _id) public view returns (Pending memory) {
        Stake memory stake = userStakes[_user][_id];
        uint amount = stake.amount;
        uint oldRewardDebt = stake.rewardDebt;

        bool islocked = block.timestamp < stake.depositTime + stake.secondsLocked; 
        uint256 depositTokenSupply = depositToken.balanceOf(address(this));

        if(amount == 0 || depositTokenSupply == 0){
            return Pending(false,0); 
        }

        uint256 reward = (block.number - lastUpdateBlock + 1) * rewardTokenPerBlock;
        
        uint256 _accRewardTokenPerShare = accRewardTokenPerShare + (reward * 1e12) / depositTokenSupply;
        uint256 _pending = ((amount * _accRewardTokenPerShare) / 1e12 - oldRewardDebt);

        uint256 bonus = timelockBonuses[stake.timelockBonus] + thresholdBonuses[stake.thresholdBonus];
        
        return Pending(islocked, _pending + bonus * _pending / 100); 
    }

    /**
     * @dev Returns the total pending rewards for a user, separated into locked and unlocked amounts.
     * @param _user The address of the user.
     * @return The total unlocked and locked pending rewards.
     */
    function pending(address _user) public view returns (uint, uint) {
        Stake[] memory stakes = userStakes[_user];
        uint totalUnlocked = 0;
        uint totalLocked = 0;
        for(uint8 i=0; i<stakes.length; i++){
            Pending memory _pending = pendingById(_user, i);
            if(_pending.isLocked){
                totalLocked += _pending.amount;
            } else {
                totalUnlocked += _pending.amount;
            }
        }
        return (totalUnlocked, totalLocked); 
    }

    /**
     * @dev Updates the reward variables to reflect the current state.
     */
    function update() public {
        if (block.number <= lastUpdateBlock) {
            return;
        }
        uint256 depositTokenSupply = depositToken.balanceOf(address(this));
        if (depositTokenSupply == 0) {
            lastUpdateBlock = block.number;
            return;
        }

        accRewardTokenPerShare += ((block.number - lastUpdateBlock) * rewardTokenPerBlock * 1e12 )/depositTokenSupply;
        lastUpdateBlock = block.number;
    }

    /**
     * @dev Allows the owner to update the stake's editability.
     * @param _id The ID of the stake.
     * @param _canEdit The new editability state.
     */
    function setEditStake(uint256 _id, bool _canEdit) public {
        Stake storage stake = userStakes[msg.sender][_id];
        stake.canEdit = _canEdit;
    }

    /**
     * @dev Internal function to calculate the reward debt based on the given amount.
     * @param _amount The amount of tokens.
     * @return The calculated reward debt.
     */
    function _getRewardDebt(uint _amount) internal view returns(uint){
        return (_amount * accRewardTokenPerShare) / 1e12;
    }

    /**
     * @dev Returns the stakes of a specific user.
     * @param user The address of the user.
     * @return An array of stakes associated with the user.
     */
    function getUserStakes(address user) external view returns (Stake[] memory) {
        return userStakes[user];
    }

    /**
     * @dev Allows the owner to update the emission rate of reward tokens per block.
     * @param _rewardTokenPerBlock The new emission rate.
     */
    function updateEmissionRate(uint256 _rewardTokenPerBlock) external onlyOwner {
        update();
        rewardTokenPerBlock = _rewardTokenPerBlock;
    }

    /**
     * @dev Allows the owner to update the emergency state of the contract.
     * @param _isEmergency The new emergency state.
     */
    function updateIsEmergency(bool _isEmergency) external onlyOwner {
        isEmergency = _isEmergency;
    }

    /**
     * @dev Allows the owner to update the paused state of the contract.
     * @param _isPaused The new paused state.
     */
    function updateIsPaused(bool _isPaused ) external onlyOwner {
        isPaused = _isPaused ;
    }

    /**
     * @dev Allows the owner to update the token custodian address.
     * @param _tokenCustodian The new token custodian address.
     */
    function updateTokenCustodian(address _tokenCustodian) external onlyOwner {
        tokenCustodian = _tokenCustodian;
    }

    /**
     * @dev Allows the owner to update the signer address.
     * @param _signer The new signer address.
     */
    function updateSigner(address _signer) external onlyOwner {
        signer = _signer;
    }

    /**
     * @dev Allows the owner to update a specific stake of a user.
     * @param _wallet The address of the user.
     * @param _id The ID of the stake to update.
     * @param _newStake The new stake data.
     */
    function updateStake(address _wallet, uint256 _id, Stake memory _newStake) external onlyOwner {
        Stake memory stake = userStakes[_wallet][_id];
        require(stake.canEdit, "Cant edit stake");
        userStakes[_wallet][_id] = _newStake;
    }

    /**
     * @dev Allows the owner to transfer tokens from the contract, except for the depositToken.
     * @param _tokenAddress The address of the token to transfer.
     */
    function saveTokens(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(depositToken), "Admin cant withdraw depositToken");
        uint bal = IERC20(_tokenAddress).balanceOf(address(this));
        IERC20(_tokenAddress).transfer(owner(), bal);
    }
}
