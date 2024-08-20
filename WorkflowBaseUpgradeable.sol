// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "./WorkflowBaseCommon.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract WorkflowBaseUpgradeable is Initializable, WorkflowBaseCommon {
    function __WorkflowBase_init() internal onlyInitializing {
        __WorkflowBase_init_unchained();
    }
    function __WorkflowBase_init_unchained() internal onlyInitializing {
    }
}