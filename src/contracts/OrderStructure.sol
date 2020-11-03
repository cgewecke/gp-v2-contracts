// SPDX-license-identifier: LGPL-3.0-or-newer
pragma solidity ^0.6.12;

/// @title Gnosis Protocol v2 Settlement Contract
/// @author Gnosis Developers
contract OrderStructure {
    struct Order {
        uint256 sellAmount;
        uint256 buyAmount;
        uint256 executedAmount;
        address sellToken;
        address buyToken;
        address owner;
        uint256 tip;
        uint32 validTo;
        uint32 nonce;
        uint8 orderType;
    }
}
