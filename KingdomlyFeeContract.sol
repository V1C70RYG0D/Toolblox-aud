// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

error InsufficientUpdateFee(uint256 requiredFee);
error ContractNotVerified(address contractAddress);

contract KingdomlyFeeContract is Ownable {
    mapping(address => bool) verifiedContracts;

    IPyth pyth;
    bytes32 ethUsdPriceId;

    constructor(address _pyth, bytes32 _ethUsdPriceId) Ownable(msg.sender) {
        pyth = IPyth(_pyth);
        ethUsdPriceId = _ethUsdPriceId;
    }

    function getOneDollarInWei() public view returns (uint256) {
        if (!verifiedContracts[msg.sender]) {
            revert ContractNotVerified(msg.sender);
        }

        PythStructs.Price memory price = pyth.getPriceNoOlderThan(ethUsdPriceId, 60);

        uint256 ethPrice18Decimals =
            (uint256(uint64(price.price)) * (10 ** 18)) / (10 ** uint8(uint32(-1 * price.expo)));
        uint256 oneDollarInWei = ((10 ** 18) * (10 ** 18)) / ethPrice18Decimals;

        return oneDollarInWei;
    }

    function updateOracleAndGetOneDollarInWei(bytes[] calldata pythPriceUpdate) public payable returns (uint256) {
        if (!verifiedContracts[msg.sender]) {
            revert ContractNotVerified(msg.sender);
        }

        uint256 updateFee = pyth.getUpdateFee(pythPriceUpdate);

        if (msg.value != updateFee) {
            revert InsufficientUpdateFee(updateFee);
        }

        pyth.updatePriceFeeds{value: msg.value}(pythPriceUpdate);

        return getOneDollarInWei();
    }

    function addVerifiedContract(address contractAddress) public onlyOwner {
        verifiedContracts[contractAddress] = true;
    }

    function removeVerifiedContract(address contractAddress) public onlyOwner {
        verifiedContracts[contractAddress] = false;
    }
}
