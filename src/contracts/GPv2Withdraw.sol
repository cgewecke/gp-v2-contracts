// SPDX-license-identifier: LGPL-3.0-or-newer
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./OrderStructure.sol";

/// @title Gnosis Protocol v2 Withdraw Contract
/// @author Gnosis Developers
contract GPv2Withdraw is Ownable, OrderStructure {
    constructor() public Ownable() {}

    function receiveTradeAmounts(Order[] memory orders) public onlyOwner {
        for (uint256 i = 0; i < orders.length; i++) {
            require(
                IERC20(orders[i].sellToken).transferFrom(
                    orders[i].owner,
                    address(owner()), // <-- settlement contract
                    orders[i].executedAmount
                ),
                "order transfer failed"
            );
        }
    }
}
