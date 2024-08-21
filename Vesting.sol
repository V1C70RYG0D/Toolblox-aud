// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract Vesting is Ownable {

    address public token;
    address treasury;

    /**
     * @dev Struct representing a vesting schedule.
     * @param isEditable Whether the schedule can be edited.
     * @param startTime The start time of the vesting schedule.
     * @param allocated The total amount of tokens allocated for vesting.
     * @param claimed The total amount of tokens claimed so far.
     * @param releaseTimestamps Array of timestamps when portions of the vested tokens are released.
     * @param releasePercentages Array of percentages representing the proportion of tokens released at each timestamp.
     */
    struct Schedule {
        bool isEditable;
        uint256 startTime;
        uint256 allocated;
        uint256 claimed;
        uint32[] releaseTimestamps; 
        uint32[] releasePercentages;
    }

    /**
     * @dev Mapping from user address to their respective vesting schedule.
     */
    mapping(address => Schedule) public schedules;

    error NoEditPermissionError(address user);
    error FormattingError(address user);

    /**
     * @dev Constructor that initializes the vesting contract.
     * @param _token The address of the token to be vested.
     * @param _treasury The address of the treasury holding the vested tokens.
     */
    constructor(address _token, address _treasury) Ownable(msg.sender) { 
        token = _token; 
        treasury = _treasury;
    }

    /**
     * @dev Sets a vesting schedule for a user. Reverts if the schedule is not editable or if there is a formatting error.
     * @param _schedule The vesting schedule to set.
     * @param _user The address of the user for whom the schedule is being set.
     */
    function setSchedule(Schedule memory _schedule, address _user) public onlyOwner(){
        
        Schedule memory schedule = schedules[_user];

        if( schedule.allocated > 0 && !schedule.isEditable){
            revert NoEditPermissionError(_user);
        }

        uint32 summedPercentages = 0;
        uint32[] memory releasePercentages = _schedule.releasePercentages;
        uint32[] memory releaseTimestamps = _schedule.releaseTimestamps;

        for(uint8 i; i < releasePercentages.length; i++){
            summedPercentages += releasePercentages[i];
        }

        // Percentages must sum to 100000000 to allow 6 decimal places of prescision
        if(summedPercentages != 100000000 || releaseTimestamps.length != releasePercentages.length){
            revert FormattingError(_user);
        }
        
        schedules[_user] = _schedule;
    }

    /**
     * @dev Sets multiple vesting schedules for multiple users. Reverts if the lengths of the input arrays do not match.
     * @dev Be careful of gas. Only send small batches.
     * @param _schedules An array of vesting schedules to set.
     * @param _users An array of user addresses for whom the schedules are being set.
     */
    function setSchedules( Schedule[] memory _schedules, address[] memory _users) public onlyOwner(){

        if(_users.length != _schedules.length){
            revert FormattingError(msg.sender);
        }
        
        for(uint i=0; i < _users.length; i++){
            setSchedule(_schedules[i], _users[i]);
        }
    }

    /**
     * @dev Sets multiple vesting schedules for multiple users based on a template schedule and individual allocations.
     * @param _template The template schedule to use for each user.
     * @param _users An array of user addresses for whom the schedules are being set.
     * @param _allocations An array of token allocations corresponding to each user.
     */
    function setSchedulesByTemplate(
        Schedule memory _template, 
        address[] memory _users, 
        uint[] memory _allocations
    ) public onlyOwner(){

        if(_users.length != _allocations.length){
            revert FormattingError(msg.sender);
        }

        for(uint i=0; i < _users.length; i++){
            Schedule memory schedule = _template;
            schedule.allocated = _allocations[i];

            setSchedule(schedule, _users[i]);
        }
    }

    /**
     * @dev Allows a user to grant edit permission for their vesting schedule.
     */
    function grantEditPermision() public {
        Schedule storage schedule = schedules[msg.sender];
        schedule.isEditable = true;
    }

    /**
     * @dev Allows a user to claim their vested tokens. Transfers the tokens from the treasury to the user.
     */
    function claim() external {
        Schedule storage schedule = schedules[msg.sender];

        uint256 unclaimed = pending(msg.sender);
        schedule.claimed += unclaimed;
        IERC20(token).transferFrom(treasury, msg.sender, unclaimed);
    }

    /**
     * @dev Returns the amount of vested tokens that are available for a user to claim.
     * @param _user The address of the user.
     * @return The amount of tokens available to claim.
     */
    function pending(address _user) public view returns(uint){
        Schedule memory schedule = schedules[_user];

        uint256 allocated = schedule.allocated;
        uint256 claimed = schedule.claimed;
        uint32[] memory releaseTimestamps = schedule.releaseTimestamps;
        uint32[] memory releasePercentages = schedule.releasePercentages;

        uint32 cumulativePercentage = 0; 
        for (uint8 i = 0; i < releaseTimestamps.length; i++) {
            if (releaseTimestamps[i] > block.timestamp) {
                break;
            }
            cumulativePercentage += releasePercentages[i];
        }
        uint256 available = (allocated * cumulativePercentage) / 100000000;
        return (available > claimed)? available - claimed : 0;
    }

    /**
     * @dev Returns the vesting schedule of a specific user.
     * @param _user The address of the user.
     * @return The vesting schedule associated with the user.
     */
    function getSchedule(address _user) public view returns(Schedule memory) {
        return schedules[_user];
    }

    /**
     * @dev Allows the owner to withdraw tokens from the contract.
     * @param amount The amount of tokens to withdraw.
     * @param _token The address of the token to withdraw.
     */
    function adminWithdraw(uint256 amount, address _token) external onlyOwner {
        IERC20(_token).transfer(owner(), amount);
    }

    /**
     * @dev Allows the owner to update the treasury address.
     * @param _treasury The new treasury address.
     */
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
}
