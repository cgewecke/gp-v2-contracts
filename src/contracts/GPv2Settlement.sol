// SPDX-license-identifier: LGPL-3.0-or-newer
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./GPv2Withdraw.sol";
import "./OrderStructure.sol";

/// @title Gnosis Protocol v2 Settlement Contract
/// @author Gnosis Developers
contract GPv2Settlement is OrderStructure {
    using SafeMath for uint256;

    /// @dev The domain separator used for signing orders that gets mixed in
    /// making signatures for different domains incompatible.
    string private constant DOMAIN_SEPARATOR = "GPv2";

    /// @dev The feeFactor is used to caluclate the charged fee: 1/FEE_FACTOR
    // min_fee_factor is a minimum and each factor used by the solver needs to be bigger
    uint256 public constant MIN_FEE_FACTOR = 1000;

    /// @dev The stride of an encoded order.
    uint256 private constant ORDER_STRIDE = 130;
    uint256 private constant INTERACTION_STRIDE = 130;

    /// @dev The stride of a uint16 returning the callData size
    uint256 private constant CALL_DATA_SIZE_STRIDE = 10;

    /// @dev Possible nonce solutions
    // mapping (address =>mapping(uint => bytes)) public bitmap;
    // function flipBitForNonce( uint nonce, address user)public {
    //     bitmap[user][(nonce%1024)/256]|=1<<(nonce%256);
    // }
    // // or
    // uint public globalnonce=0;

    /// @dev Replay protection that is mixed with the order data for signing.
    /// This is done in order to avoid chain and domain replay protection, so
    /// that signed orders are only valid for specific GPv2 contracts.
    ///
    /// The replay protection is defined as the Keccak-256 hash of `"GPv2"`
    /// followed by the chain ID and finally the contract address.
    bytes32 public immutable replayProtection;

    GPv2Withdraw public immutable withdrawContract;

    struct Interaction {
        bytes callData;
        address interactionTarget;
    }

    /// GPv2 settlement contract.
    constructor() public {
        uint256 chainId;
        // NOTE: Currently, the only way to get the chain ID in solidity is
        // using assembly.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            chainId := chainid()
        }

        replayProtection = keccak256(
            abi.encode(DOMAIN_SEPARATOR, chainId, address(this))
        );
        withdrawContract = new GPv2Withdraw();
    }

    function settle(
        bytes calldata encodedInteractions,
        uint256 numberOfInteractions,
        uint256[] memory clearingPrices,
        address[] memory tokens,
        bytes calldata encodedOrders,
        uint feeFactor
    ) external {
        Order[] memory orders = decodeOrders(encodedOrders);
        withdrawContract.receiveTradeAmounts(orders);
        //todo: replay protection orders: Either global nonces or bitmaps cancelations

        Interaction[] memory Interactions = decodeInteractions(
            encodedInteractions,
            numberOfInteractions
        );
        executeInteractions(Interactions);

        settleOrders(orders, clearingPrices, tokens, feeFactor);
    }

    function executeInteractions(Interaction[] memory Interactions) internal {
        for (uint256 i = 0; i < Interactions.length; i++) {
            // to prevent possible attacks against users funds, 
            // interactions with the withdrawContract are not allowed
            require(
                Interactions[i].interactionTarget != address(withdrawContract),
                "Interactions with withdraw contract are not allowed"
            );
            // An external contract interaction might need to have several 
            // interactions - e.g. for uniswap exvchange, we would have one transfer and 
            // one swap interaction
            (Interactions[i].interactionTarget).call(Interactions[i].callData);
        }
    }

    function decodeSingleOrder(bytes calldata orderBytes)
        internal
        pure
        returns (GPv2Settlement.Order memory orders)
    {
        (
            uint256 sellAmount,
            uint256 buyAmount,
            uint256 executedAmount,
            address sellToken,
            address buyToken,
            uint256 tip,
            uint32 validTo,
            uint32 nonce,
            uint8 v,
            bytes32 r,
            bytes32 s
        ) = abi.decode(
            orderBytes,
            (
                uint256,
                uint256,
                uint256,
                address,
                address,
                uint256,
                uint32,
                uint32,
                uint8,
                bytes32,
                bytes32
            )
        );
        bytes32 digest = keccak256(
            abi.encode(
                DOMAIN_SEPARATOR,
                sellAmount,
                buyAmount,
                sellToken,
                buyToken,
                tip,
                validTo,
                nonce,
                0 // for simplicity, we assume all orders are killOrFill
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0), "invalid_signature");
        return
            Order({
                sellAmount: sellAmount,
                buyAmount: buyAmount,
                executedAmount: executedAmount,
                buyToken: buyToken,
                sellToken: sellToken,
                owner: recoveredAddress,
                tip: tip,
                validTo: validTo,
                nonce: nonce,
                orderType: 0
            });
    }

    function decodeSingleInteraction(bytes calldata interactionBytes)
        internal
        pure
        returns (Interaction memory interaction)
    {
        (
            address interactionTarget
        ) = abi.decode(
            interactionBytes[:INTERACTION_STRIDE],
            (address)
        );
        bytes memory callData = abi.decode(
            interactionBytes[INTERACTION_STRIDE:],
            (bytes)
        );
        return
            Interaction({
                callData: callData,
                interactionTarget: interactionTarget
            });
    }

    function decodeInteractions(
        bytes calldata interactionBytes,
        uint256 numberOfInteractions
    ) internal pure returns (Interaction[] memory interactions) {
        interactions = new Interaction[](numberOfInteractions);
        for (uint256 i = 0; i < numberOfInteractions; i++) {
            uint256 callDataSize = uint256(
                abi.decode(interactionBytes[:CALL_DATA_SIZE_STRIDE], (uint16))
            );
            interactionBytes = interactionBytes[CALL_DATA_SIZE_STRIDE:];


                bytes calldata singleInteraction
             = interactionBytes[:INTERACTION_STRIDE + callDataSize];
            interactions[i] = decodeSingleInteraction(singleInteraction);
            interactionBytes = interactionBytes[INTERACTION_STRIDE +
                callDataSize:];
        }
    }

    function decodeOrders(bytes calldata orderBytes)
        internal
        pure
        returns (Order[] memory orders)
    {
        require(
            orderBytes.length % ORDER_STRIDE == 0,
            "malformed encoded orders"
        );
        orders = new Order[](orderBytes.length / ORDER_STRIDE);
        uint256 count = 0;
        while (orderBytes.length > 0) {
            bytes calldata singleOrder = orderBytes[:ORDER_STRIDE];
            orderBytes = orderBytes[ORDER_STRIDE:];
            orders[count] = decodeSingleOrder(singleOrder);
            count = count + 1;
        }
    }

    function settleOrders(
        Order[] memory orders,
        uint256[] memory clearingPrices,
        address[] memory tokens,
        uint feeFactor
    ) internal {
        require(feeFactor> MIN_FEE_FACTOR ,"fee not set correctly");
        for (uint256 i = 0; i < orders.length; i++) {
            uint256 soldAmount = (orders[i].executedAmount * (feeFactor - 1)) /
                feeFactor;
            (
                uint256 clearingPriceNum,
                uint256 clearingPriceDen
            ) = getClearingPrice(
                orders[i].sellToken,
                orders[i].buyToken,
                clearingPrices,
                tokens
            );
            // verify limit prices:
            require(
                clearingPriceNum.mul(orders[i].sellAmount).mul(feeFactor) <=
                    clearingPriceDen.mul(orders[i].buyAmount).mul(feeFactor - 1),
                "clearing prices not met"
            );
            // verify that killOrFill orders are fully matched
            if (orders[i].orderType == 0) {
                require(
                    orders[i].executedAmount == orders[i].sellAmount,
                    "killOrFill order not fully filled"
                );
            }
            uint256 amountReceived = soldAmount.mul(clearingPriceNum).div(
                clearingPriceDen
            );
            require(
                IERC20(orders[i].buyToken).transfer(
                    orders[i].owner,
                    amountReceived
                ),
                "settlement's transfer failed"
            );
        }
    }

    function getClearingPrice(
        address sellToken,
        address buyToken,
        uint256[] memory clearingPrices,
        address[] memory tokens
    ) internal pure returns (uint256, uint256) {
        return (
            clearingPrices[findTokenIndex(sellToken, tokens)],
            clearingPrices[findTokenIndex(buyToken, tokens)]
        );
    }

    function findTokenIndex(address token, address[] memory tokens)
        private
        pure
        returns (uint256)
    {
        // binary search for the other tokens
        uint256 leftValue = 0;
        uint256 rightValue = tokens.length - 1;
        while (rightValue >= leftValue) {
            uint256 middleValue = (leftValue + rightValue) / 2;
            if (tokens[middleValue] == token) {
                // shifted one to the right to account for fee token at index 0
                return middleValue;
            } else if (tokens[middleValue] < token) {
                leftValue = middleValue + 1;
            } else {
                rightValue = middleValue - 1;
            }
        }
        revert("Price not provided for token");
    }
}
