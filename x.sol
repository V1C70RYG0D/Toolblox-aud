// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

// Assuming these are custom contracts you have access to
import "./NonTransferrableERC721Upgradeable.sol";
import "./WorkflowBaseUpgradeable.sol";

/**
 * @title ProfileWorkflow
 * @dev This contract serves as the holder for decentralized social network profiles.
 * The profile is a soulbound upgradeable NFT (ERC721).
 */
contract ProfileWorkflow is Initializable, OwnableUpgradeable, NonTransferrableERC721Upgradeable, WorkflowBaseUpgradeable {

    struct Profile {
        uint id;
        uint64 status;
        address wallet;
        string image;
        string name;
        string description;
    }

    mapping(uint => Profile) public items;
    mapping(address => uint) public itemsByWallet;

    

    function initialize(address _newOwner) public initializer {
        __Ownable_init(_newOwner);
        __NonTransferrableERC721_init();
        __ERC721_init("Profile - PROFILE test profile v1", "PROFILE");
        __WorkflowBase_init();
    }

    function _assertOrAssignWallet(Profile memory item) private view {
        address wallet = item.wallet;
        if (wallet != address(0)) {
            require(_msgSender() == wallet, "Invalid Wallet");
            return;
        }
        item.wallet = _msgSender();
    }

    function _assertStatus(Profile memory item, uint64 status) private pure {
        require(item.status == status, "Cannot run Workflow action; unexpected status");
    }

    function getItem(uint256 id) public view returns (Profile memory) {
        Profile memory item = items[id];
        require(item.id == id, "Cannot find item with given id");
        return item;
    }

    function registerProfile(string calldata name) public returns (uint256) {
        uint256 id = _getNextId();
        Profile memory item;
        item.id = id;
        _assertOrAssignWallet(item);
        _setItemIdByWallet(item, 0);
        item.name = name;
        item.status = 0;
        items[id] = item;
        address newOwner = getItemOwner(item);
        _mint(newOwner, id);
        _setItemIdByWallet(item, id);
        emit ItemUpdated(id, item.status);
        return id;
    }

    function changeName(uint256 id, string calldata name) public returns (uint256) {
        Profile memory item = getItem(id);
        address oldOwner = getItemOwner(item);
        _assertOrAssignWallet(item);
        _assertStatus(item, 0);
        _setItemIdByWallet(item, 0);
        item.name = name;
        item.status = 0;
        items[id] = item;
        address newOwner = getItemOwner(item);
        if (newOwner != oldOwner) {
            _transfer(oldOwner, newOwner, id);
        }
        _setItemIdByWallet(item, id);
        emit ItemUpdated(id, item.status);
        return id;
    }

    function getItemOwner(Profile memory item) private view returns (address itemOwner) {
        if (item.status == 0) {
            itemOwner = item.wallet;
        } else {
            itemOwner = address(this);
        }
    }

    function _setItemIdByWallet(Profile memory item, uint id) private {
        if (item.wallet == address(0)) return;
        uint existingItemByWallet = itemsByWallet[item.wallet];
        require(existingItemByWallet == 0 || existingItemByWallet == item.id,
            "Cannot set Wallet. Another item already exists with same value.");
        itemsByWallet[item.wallet] = id;
    }

    function _getNextId() internal view override returns (uint256) {
        // Implement logic to generate the next ID
        return 0; // Placeholder
    }
}