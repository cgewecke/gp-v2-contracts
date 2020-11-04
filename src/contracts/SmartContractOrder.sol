// SPDX-license-identifier: LGPL-3.0-or-newer
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/// @title Example of a smart contract Order
/// @author Gnosis Developers
contract SmartContractOrder {
    using SafeMath for uint256;

    uint256 public priceDen;
    uint256 public priceNum;
    IERC20 public sellToken;
    IERC20 public buyToken;
    uint256 public boughtAmount = 0;
    address public settlementContract;

    modifier onlySettlementContract() {
        require(
            msg.sender == settlementContract,
            "Only settlement contract can call this function."
        );
        _;
    }

    constructor(
        uint256 _priceNum,
        uint256 _priceDen,
        IERC20 _sellToken,
        IERC20 _buyToken,
        address _settlementContract
    ) public {
        priceNum = _priceNum;
        priceDen = _priceDen;
        sellToken = _sellToken;
        buyToken = _buyToken;
        settlementContract = _settlementContract;
    }

    function settle(
        uint256 clearingPriceNum,
        uint256 clearingPriceDen,
        bytes calldata _additional_information
    ) public onlySettlementContract() {
        uint256 buyAmount = buyToken.balanceOf(address(this)) - boughtAmount;
        boughtAmount = buyAmount;
        require(
            clearingPriceNum.mul(priceDen) <= clearingPriceDen.mul(priceNum),
            "limit price not respected"
        );
        uint256 sellAmount = buyAmount.mul(clearingPriceNum).div(
            clearingPriceDen
        );
        require(sellToken.transfer(msg.sender, sellAmount), "transfer failed");
    }
}
