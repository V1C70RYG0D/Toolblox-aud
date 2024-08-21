
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LearnToken is ERC20, Ownable {
  constructor() ERC20("Brainedge Learn Token", "LEARN") Ownable(msg.sender){
    _mint(msg.sender, 10**28);
  } 
}
