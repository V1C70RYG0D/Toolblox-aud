// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./KingdomlyFeeContract.sol";

event PoolInitialized(string poolName, IERC721[] collections, uint256[] dailyRewards);

event Staked(address user, uint256[] tokenIds, address collection);

event Withdrawn(address user, uint256[] tokenIds, address collection);

event AddressMultiplierSet(address[] users, uint256[] multipliers);

event AddressPointBoostsApplied(address[] users, uint256[] pointBoosts);

event TokenMultiplierSet(address collection, uint256[] tokenIds, uint256[] multipliers);

event RewardRedemptionStarted();

event RewardTokenDeposited(address rewardToken, uint256 amount);

event RewardTokenWithdrawn(address rewardToken, uint256 amount);

event RewardTokenRedeemed(address user, address rewardToken, uint256 amount);

event RewardPointsRedeemed(address user, uint256 amount);

// ########## ERRORS ##########

error UnauthorizedAccess();

error InsufficientStakingFee();

error InvalidEmptyArrayInput();

error MismatchedArrays();

error TokenNotStakedByUser();

error InvalidTokenAddress();

error InvalidRewardTokenAmount();

error UnsupportedCollection();

error StakedTokenMismatch();

error RedemptionStatusMismatch();
/**
 * @title KingdomlyNFTStakingPool
 * @dev This contract allows users to stake NFTs, earn points, and redeem rewards in the form of ERC20 tokens.
 * It includes functionalities for admins to manage reward tokens, set multipliers, and manually boost points.
 */

contract KingdomlyNFTStakingPool is ERC721Holder, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Structs
    struct StakedToken {
        uint256 tokenId;
        address collection;
        uint256 stakedAt;
    }

    /// @notice The name of the staking pool.
    string public poolName;

    /// @notice The collections supported in this staking pool.
    IERC721[] public collections;

    /// @notice Index mapping of collections.
    mapping(address => uint256) public collectionsIndex;

    /// @notice Mapping to check if a collection is supported.
    mapping(address => bool) public collectionSupported;

    /// @notice Mapping from collection address to its daily points.
    mapping(address => uint256) public collectionDailyPoints;

    /// @notice The reward token used in this staking pool.
    IERC20 public rewardToken;

    /// @notice The total amount of reward tokens deposited into the contract.
    uint256 public depositedRewardTokenAmount;

    /// @notice The total number of active stakers.
    uint256 public totalActiveStakers;

    /// @notice The total number of tokens currently staked.
    uint256 public totalStakedTokens;

    /// @notice Mapping from collection address to tokenId to multiplier.
    mapping(address => mapping(uint256 => uint256)) public tokenMultiplier;

    /// @notice Mapping from user address to their address-specific multiplier.
    mapping(address => uint256) public addressMultiplier;

    /// @notice Mapping from collection address to tokenId to the user who staked it.
    mapping(address => mapping(uint256 => address)) public stakedAssets;

    /// @notice Mapping from user address to an array of tokens they have staked.
    mapping(address => StakedToken[]) public tokensStaked;

    /// @notice Mapping from collection address and tokenId to index in `tokensStaked`.
    mapping(address => mapping(uint256 => uint256)) public collectionTokenIdToIndex;

    /// @notice Mapping from user address to their stored points (updated after withdrawals).
    mapping(address => uint256) public storedPoints;

    /// @notice Mapping from user address to their redeemed points.
    mapping(address => uint256) public redeemedPoints;

    /// @notice Mapping to check if a user has redeemed points.
    mapping(address => bool) public hasRedeemed;

    /// @notice Indicates whether the reward redemption period has started.
    bool public rewardRedemptionStarted;

    /// @notice The timestamp when the reward redemption period started.
    uint256 public rewardRedemptionStartTimestamp;

    /// @notice The total pool points (includes all calculated points).
    uint256 public totalPoolPoints;

    /// @notice The total points that have been redeemed from the pool.
    uint256 public totalPoolRedeemedPoints;

    /// @notice The Kingdomly Admin address needed for Fee Contract.
    address public kingdomlyAdmin;

    /// @notice The Kingdomly Fee Contract address needed for Fee Calculations.
    KingdomlyFeeContract public kingdomlyFeeContract;

    /// @notice This is the Dollar fee for Depositing and Withdrawing
    uint256 public immutable stakingFeeInCents;

    /**
     * @notice Initializes the staking pool with a name, collections, and their corresponding daily points.
     * @param _poolName The name of the staking pool.
     * @param _collections An array of NFT collections supported by this pool.
     * @param _dailyPoints An array of daily points corresponding to each collection.
     */
    constructor(
        string memory _poolName,
        IERC721[] memory _collections,
        uint256[] memory _dailyPoints,
        address _kingdomlyAdmin,
        KingdomlyFeeContract _kingdomlyFeeContract
    ) Ownable(msg.sender) {
        if (_collections.length == 0 || _dailyPoints.length == 0) {
            revert InvalidEmptyArrayInput();
        }
        if (_collections.length != _dailyPoints.length) {
            revert MismatchedArrays();
        }

        poolName = _poolName;

        for (uint256 i; i < _collections.length;) {
            collections.push(_collections[i]);
            collectionsIndex[address(_collections[i])] = i;
            collectionSupported[address(_collections[i])] = true;
            collectionDailyPoints[address(_collections[i])] = _dailyPoints[i];

            unchecked {
                i++;
            }
        }

        kingdomlyAdmin = _kingdomlyAdmin;
        kingdomlyFeeContract = _kingdomlyFeeContract;

        stakingFeeInCents = 150; // $1.5 * 100 = 150

        emit PoolInitialized(_poolName, _collections, _dailyPoints);
    }

    // ###################### Modifiers ######################

    /**
     * @dev Ensures the caller is the Kingdomly Admin.
     */
    modifier isKingdomlyAdmin() {
        if (msg.sender != kingdomlyAdmin) {
            revert UnauthorizedAccess();
        }

        _;
    }

    /**
     * @dev Ensures that the reward redemption status matches the expected value.
     * @param _expected The expected status of the reward redemption period (true if active, false if not).
     */
    modifier rewardRedemptionActive(bool _expected) {
        if (rewardRedemptionStarted != _expected) {
            revert RedemptionStatusMismatch();
        }

        _;
    }

    /**
     * @dev Updates the stored points for a user during withdrawals. It increments the user's stored points
     * mapping, which will be used at the end during the redemption of points.
     * @param _user The address of the user whose points are being updated.
     * @param _collection The address of the NFT collection from which the tokens are being withdrawn.
     * @param _tokenIds The array of token IDs being withdrawn.
     */
    modifier updateStoredPoints(address _user, address _collection, uint256[] calldata _tokenIds) {
        if (!hasRedeemed[_user]) {
            // If the user has not previously redeemed points, update the user's stored points.
            if (_user != address(0) && _collection != address(0)) {
                for (uint256 i; i < _tokenIds.length;) {
                    if (stakedAssets[_collection][_tokenIds[i]] != msg.sender) {
                        revert TokenNotStakedByUser();
                    }

                    unchecked {
                        i++;
                    }
                }

                uint256 newUserRewards = calculateUserPointsFromStakedTokens(_user, _collection, _tokenIds);
                storedPoints[_user] += newUserRewards;

                if (!rewardRedemptionStarted) totalPoolPoints += newUserRewards; // Increment the total pool rewards with every withdrawal ONLY IF the reward redemption has not started
            }
        }
        _;
    }

    // ###################### Pool Configuration Functions ######################

    // Reward Functions

    /**
     * @notice Deposits the specified amount of reward tokens into the pool.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * @param _token The ERC20 token to be deposited as a reward.
     * @param _amount The amount of the ERC20 token to be deposited.
     * Emits a {RewardTokenDeposited} event.
     */
    function depositRewardToken(IERC20 _token, uint256 _amount) external onlyOwner rewardRedemptionActive(false) {
        if (address(_token) == address(0)) {
            revert InvalidTokenAddress();
        }
        if (_amount == 0) {
            revert InvalidRewardTokenAmount();
        }

        rewardToken = _token;
        depositedRewardTokenAmount = _amount;

        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);

        emit RewardTokenDeposited(address(_token), _amount);
    }

    /**
     * @notice Increases the amount of deposited reward tokens in the pool.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * @param _amount The additional amount of the ERC20 token to be deposited.
     */
    function increaseDepositedRewardTokenAmount(uint256 _amount) external onlyOwner rewardRedemptionActive(false) {
        if (address(rewardToken) == address(0)) {
            revert InvalidTokenAddress();
        }
        if (_amount == 0) {
            revert InvalidRewardTokenAmount();
        }

        depositedRewardTokenAmount += _amount;

        rewardToken.safeTransferFrom(msg.sender, address(this), _amount);

        // emit RewardTokenDeposited(address(rewardToken), _amount);
    }

    /**
     * @notice Withdraws the deposited reward tokens from the pool.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * Emits a {RewardTokenWithdrawn} event.
     */
    function withdrawRewardToken() external onlyOwner rewardRedemptionActive(false) {
        if (address(rewardToken) == address(0)) {
            revert InvalidTokenAddress();
        }

        rewardToken.safeTransfer(msg.sender, depositedRewardTokenAmount);

        emit RewardTokenWithdrawn(address(rewardToken), depositedRewardTokenAmount);
    }

    /**
     * @notice Starts the reward redemption process.
     * @dev This function calculates the total points from staked tokens on-chain, which is an expensive call.
     * It can only be called by the owner and before reward redemption has started.
     * Emits a {RewardRedemptionStarted} event.
     */
    function startRewardRedemption() external onlyOwner rewardRedemptionActive(false) {
        rewardRedemptionStarted = true;
        rewardRedemptionStartTimestamp = block.timestamp;

        emit RewardRedemptionStarted();
    }

    /**
     * @notice Starts the reward redemption process with total points calculated off-chain.
     * @dev This function allows the total points being currently staked to be calculated off-chain and passed to the contract.
     * It can only be called by the owner and before reward redemption has started.
     * @param _totalPoolPoints The total points from staked tokens, calculated off-chain, to be added to the total pool points.
     * Emits a {RewardRedemptionStarted} event.
     */
    function startRewardRedemption_OFF_CHAIN(uint256 _totalPoolPoints)
        external
        onlyOwner
        rewardRedemptionActive(false)
    {
        rewardRedemptionStarted = true;
        totalPoolPoints += _totalPoolPoints; // The total points from the staked tokens(calculated OFF CHAIN) are added to the total pool points
        rewardRedemptionStartTimestamp = block.timestamp;

        emit RewardRedemptionStarted();
    }

    // Multiplier / Booster Functions

    /**
     * @notice Sets multipliers for specific users, affecting their reward points calculation.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * @param _users An array of user addresses for which the multipliers are to be set.
     * @param _multipliers An array of multiplier values corresponding to each user address.
     * Requirements:
     * - `_users` and `_multipliers` must have the same length.
     * Emits an {AddressMultiplierSet} event.
     */
    function setAddressMultiplier(address[] memory _users, uint256[] memory _multipliers)
        external
        onlyOwner
        rewardRedemptionActive(false)
    {
        if (_users.length == 0 || _multipliers.length == 0) {
            revert InvalidEmptyArrayInput();
        }
        if (_users.length != _multipliers.length) {
            revert MismatchedArrays();
        }

        for (uint256 i; i < _users.length;) {
            addressMultiplier[_users[i]] = _multipliers[i];

            unchecked {
                i++;
            }
        }

        emit AddressMultiplierSet(_users, _multipliers);
    }

    /**
     * @notice Sets multipliers for specific tokens within a collection, affecting their reward points calculation.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * @param _collection The address of the token collection.
     * @param _tokenIds An array of token IDs for which the multipliers are to be set.
     * @param _multipliers An array of multiplier values corresponding to each token ID.
     * Requirements:
     * - `_tokenIds` and `_multipliers` must have the same length.
     * Emits a {TokenMultiplierSet} event.
     */
    function setTokenMultiplier(address _collection, uint256[] memory _tokenIds, uint256[] memory _multipliers)
        external
        onlyOwner
        rewardRedemptionActive(false)
    {
        if (_tokenIds.length == 0 || _multipliers.length == 0) {
            revert InvalidEmptyArrayInput();
        }
        if (_tokenIds.length != _multipliers.length) {
            revert MismatchedArrays();
        }

        for (uint256 i; i < _tokenIds.length;) {
            tokenMultiplier[_collection][_tokenIds[i]] = _multipliers[i];

            unchecked {
                i++;
            }
        }

        emit TokenMultiplierSet(_collection, _tokenIds, _multipliers);
    }

    /**
     * @notice Adds a points boost to specific users, manually increasing their stored points.
     * @dev This function can only be called by the owner and before reward redemption has started.
     * @param _users An array of user addresses to receive the points boost.
     * @param _pointBoosts An array of point boost values corresponding to each user address.
     * Requirements:
     * - `_users` and `_pointBoosts` must have the same length.
     * Emits an {AddressPointBoostsApplied} event.
     */
    function setAddressPointBooster(address[] calldata _users, uint256[] calldata _pointBoosts)
        public
        onlyOwner
        rewardRedemptionActive(false)
    {
        if (_users.length == 0 || _pointBoosts.length == 0) {
            revert InvalidEmptyArrayInput();
        }
        if (_users.length != _pointBoosts.length) {
            revert MismatchedArrays();
        }

        for (uint256 i; i < _users.length;) {
            storedPoints[_users[i]] = _pointBoosts[i];

            unchecked {
                i++;
            }
        }

        emit AddressPointBoostsApplied(_users, _pointBoosts);
    }

    // ###################### Staking Functions ######################

    /**
     * @notice Allows a user to stake their NFTs from a supported collection.
     * @dev Transfers the specified NFTs from the user to the contract and updates the staking records.
     * This function can only be called when reward redemption is not active.
     * @param _collection The address of the NFT collection to stake.
     * @param _tokenIds An array of token IDs from the collection to be staked.
     * Requirements:
     * - `_tokenIds` must not be empty.
     * - `_collection` must be supported by the contract.
     * Emits a {Staked} event.
     */
    function stake(IERC721 _collection, uint256[] calldata _tokenIds)
        external
        payable
        rewardRedemptionActive(false)
        nonReentrant
    {
        if (_tokenIds.length == 0) {
            revert InvalidEmptyArrayInput();
        }
        if (!collectionSupported[address(_collection)]) {
            revert UnsupportedCollection();
        }

        // Assuming getOneDollarInWei() returns the wei value for 1 dollar
        uint256 totalStakingFee = getStakeFee();

        if (msg.value != totalStakingFee) {
            revert InsufficientStakingFee();
        }

        for (uint256 i; i < _tokenIds.length;) {
            _collection.safeTransferFrom(msg.sender, address(this), _tokenIds[i]);

            stakedAssets[address(_collection)][_tokenIds[i]] = msg.sender;
            StakedToken memory stakedToken = StakedToken(_tokenIds[i], address(_collection), block.timestamp);
            tokensStaked[msg.sender].push(stakedToken);
            collectionTokenIdToIndex[address(_collection)][_tokenIds[i]] = tokensStaked[msg.sender].length - 1;

            unchecked {
                i++;
            }
        }
        totalStakedTokens += _tokenIds.length;

        StakedToken[] memory stakedTokens = tokensStaked[msg.sender];
        if (stakedTokens.length - _tokenIds.length == 0) {
            // If the tokens staked now subtracted from the total tokens staked by the user is 0
            // Means the user just staked for the first time and we increment the total active stakers
            totalActiveStakers++;
        }

        emit Staked(msg.sender, _tokenIds, address(_collection));
    }

    /**
     * @notice Allows a user to withdraw their staked NFTs from the contract.
     * @dev Transfers the specified NFTs back to the user and updates the staking records.
     * This function updates the user's stored points based on the staked NFTs.
     * @param _collection The address of the NFT collection to withdraw from.
     * @param _tokenIds An array of token IDs from the collection to be withdrawn.
     * Requirements:
     * - `_tokenIds` must not be empty.
     * Emits a {Withdrawn} event.
     */
    function withdraw(IERC721 _collection, uint256[] calldata _tokenIds)
        external
        payable
        nonReentrant
        updateStoredPoints(msg.sender, address(_collection), _tokenIds)
    {
        if (_tokenIds.length == 0) {
            revert InvalidEmptyArrayInput();
        }

        uint256 totalStakingFee = getStakeFee();

        if (msg.value != totalStakingFee) {
            revert InsufficientStakingFee();
        }

        for (uint256 i; i < _tokenIds.length;) {
            delete stakedAssets[address(_collection)][_tokenIds[i]];

            // Swap Withdrawn token with token in the last index of user's staked tokens
            // and update the index of the swapped token before popping the last element
            StakedToken[] storage userStakedTokens = tokensStaked[msg.sender];

            uint256 currentTokenIndex = collectionTokenIdToIndex[address(_collection)][_tokenIds[i]];

            uint256 lastUserStakedTokenIndex = userStakedTokens.length - 1;

            if (currentTokenIndex != lastUserStakedTokenIndex) {
                StakedToken memory userLastStakedToken = userStakedTokens[lastUserStakedTokenIndex];
                userStakedTokens[currentTokenIndex] = userLastStakedToken;
                collectionTokenIdToIndex[address(_collection)][userLastStakedToken.tokenId] = currentTokenIndex;
            }
            userStakedTokens.pop();

            // Return NFT to user
            _collection.safeTransferFrom(address(this), msg.sender, _tokenIds[i]);

            unchecked {
                i++;
            }
        }
        totalStakedTokens -= _tokenIds.length;
        StakedToken[] memory stakedTokens = tokensStaked[msg.sender];
        if (stakedTokens.length == 0) {
            totalActiveStakers--;
        }

        emit Withdrawn(msg.sender, _tokenIds, address(_collection));
    }

    // ###################### Reward Redemption Functions ######################

    /**
     * @notice Allows a user to redeem their accumulated rewards based on their staked NFTs.
     * @dev The reward is calculated and transferred to the user if a reward token has been set.
     * This function can only be called when reward redemption is active.
     * Emits a {RewardPointsRedeemed} event and, if applicable, a {RewardTokenRedeemed} event.
     */
    function redeemRewards() external nonReentrant rewardRedemptionActive(true) {
        uint256 totalUserPoints = getTotalUserPoints(msg.sender);

        storedPoints[msg.sender] = 0;
        redeemedPoints[msg.sender] = totalUserPoints;

        if (address(rewardToken) != address(0)) {
            // This part of the code only runs if a reward token has been set
            uint256 userRewardPercentage = getUserRedeemedPointsPercentage(msg.sender);

            uint256 tokenRewardAmount = (depositedRewardTokenAmount * userRewardPercentage) / 1_000_000;

            rewardToken.safeTransfer(msg.sender, tokenRewardAmount);

            emit RewardTokenRedeemed(msg.sender, address(rewardToken), tokenRewardAmount);
        }

        // These points are just stored and can be used by the admins if they would like to run some
        // other airdrop and need these redeemed points
        totalPoolRedeemedPoints += totalUserPoints;

        hasRedeemed[msg.sender] = true;

        emit RewardPointsRedeemed(msg.sender, depositedRewardTokenAmount);
    }

    // ###################### Kingdomly Admin Functions ######################

    function setNewKingdomlyFeeContract(KingdomlyFeeContract _kingdomlyFeeContract) external isKingdomlyAdmin {
        kingdomlyFeeContract = _kingdomlyFeeContract;
    }

    // ###################### Fee Functions ######################

    function getOneDollarInWei() internal view returns (uint256) {
        return kingdomlyFeeContract.getOneDollarInWei();
    }

    // ###################### View Functions ######################

    /**
     * @notice Calculates the total points a user has accumulated based on their currently staked tokens.
     * @dev This function only accounts for rewards from currently staked tokens and does not include withdrawn tokens.
     * @param _user The address of the user whose staked token points are being calculated.
     * @return The total calculated reward points for the user.
     */
    function calculateUserCurrentlyStakedTokenPoints(address _user) public view returns (uint256) {
        StakedToken[] memory userStakedTokens = tokensStaked[_user];

        uint256 userCalculatedRewards = 0;

        for (uint256 i; i < userStakedTokens.length;) {
            uint256 totalMultiplier =
                getTotalMultiplier(_user, userStakedTokens[i].collection, userStakedTokens[i].tokenId);

            uint256 calculationTimestamp =
                rewardRedemptionStartTimestamp != 0 ? rewardRedemptionStartTimestamp : block.timestamp;
            // The timestamp used for the calculation depends on if the reward redemption period has started.
            // If not, it uses the current timestamp; if yes, it uses the redemption period timestamp to ensure
            // that days after that time period are not calculated.

            uint256 stakedDays = (calculationTimestamp - userStakedTokens[i].stakedAt) / 86400;

            // The calculated rewards will be the total multiplier multiplied by the specific collection's daily points,
            // multiplied by the number of days staked.
            userCalculatedRewards +=
                totalMultiplier * collectionDailyPoints[userStakedTokens[i].collection] * stakedDays;

            unchecked {
                i++;
            }
        }
        return userCalculatedRewards;
    }

    /**
     * @notice Calculates the reward points a user has earned from a specific set of staked token IDs.
     * @dev This function is used within the `updateStoredPoints` modifier to update a user's rewards upon withdrawal.
     * @param _user The address of the user whose rewards are being calculated.
     * @param _collection The address of the NFT collection.
     * @param _tokenIds An array of token IDs for which the rewards are calculated.
     * @return The total calculated reward points for the specified tokens.
     */
    function calculateUserPointsFromStakedTokens(address _user, address _collection, uint256[] calldata _tokenIds)
        internal
        view
        returns (uint256)
    {
        StakedToken[] memory userStakedTokens = tokensStaked[msg.sender];

        uint256 userCalculatedRewards = 0;

        for (uint256 i; i < _tokenIds.length;) {
            uint256 stakedTokenIndex = collectionTokenIdToIndex[_collection][_tokenIds[i]];

            StakedToken memory stakedToken = userStakedTokens[stakedTokenIndex];
            if (stakedToken.tokenId != _tokenIds[i]) {
                revert StakedTokenMismatch();
            }

            uint256 totalMultiplier = getTotalMultiplier(_user, stakedToken.collection, stakedToken.tokenId);

            uint256 calculationTimestamp =
                rewardRedemptionStartTimestamp != 0 ? rewardRedemptionStartTimestamp : block.timestamp;
            uint256 stakedDays = (calculationTimestamp - userStakedTokens[i].stakedAt) / 86400;

            // The calculated rewards will be the total multiplier multiplied by the specific collection's daily points,
            // multiplied by the number of days staked.
            userCalculatedRewards +=
                totalMultiplier * collectionDailyPoints[userStakedTokens[i].collection] * stakedDays;

            unchecked {
                i++;
            }
        }
        return userCalculatedRewards;
    }

    /**
     * @notice Gets the total multiplier for a user based on their address, collection, and token ID.
     * @dev Combines the address multiplier and token multiplier. If both are zero, returns a default multiplier of 1.
     * @param _user The address of the user.
     * @param _collection The address of the NFT collection.
     * @param _tokenId The token ID of the NFT.
     * @return The combined multiplier value.
     */
    function getTotalMultiplier(address _user, address _collection, uint256 _tokenId) public view returns (uint256) {
        uint256 _userMultiplier = addressMultiplier[_user];
        uint256 _tokenMultiplier = tokenMultiplier[_collection][_tokenId];

        // If the sum of multipliers is 0, return 1.
        uint256 totalMultiplier = _userMultiplier + _tokenMultiplier != 0 ? _userMultiplier + _tokenMultiplier : 1;

        return totalMultiplier;
    }

    /**
     * @notice Calculates the percentage of a user's redeemed points relative to the total pool points.
     * @dev This function gives the percentage with 4 decimal places.
     * @param _user The address of the user.
     * @return The user's redeemed points percentage as a value out of 1,000,000 (to give 4 decimal places).
     */
    function getUserRedeemedPointsPercentage(address _user) public view returns (uint256) {
        uint256 _addressPointsPercentage = (((redeemedPoints[_user] * 1_000_000) / totalPoolPoints)); // To give a percentage with 4 decimal places.
        return _addressPointsPercentage;
    }

    /**
     * @notice Returns the total reward points of a user, including both withdrawn and currently staked tokens.
     * @param _user The address of the user.
     * @return The total reward points for the user.
     */
    function getTotalUserPoints(address _user) public view returns (uint256) {
        return storedPoints[_user] + calculateUserCurrentlyStakedTokenPoints(_user);
    }

    /**
     * @notice Returns the amount needed to pay for staking and unstaking.
     * @return The stake fee.
     */
    function getStakeFee() public view returns (uint256) {
        return (getOneDollarInWei() / 100) * stakingFeeInCents;
    }
}
