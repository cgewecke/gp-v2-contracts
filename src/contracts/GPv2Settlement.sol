// SPDX-license-identifier: LGPL-3.0-or-newer
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/// @title Gnosis Protocol v2 Settlement Contract
/// @author Gnosis Developers
contract GPv2Settlement {
    using SafeMath for uint256;

    /// @dev The domain separator used for signing orders that gets mixed in
    /// making signatures for different domains incompatible.
    string private constant DOMAIN_SEPARATOR = "GPv2";

    /// @dev The stride of an encoded order.
    uint256 private constant ORDER_STRIDE = 130;
    uint256 private constant TRADE_STRIDE = 130;

    /// @dev Replay protection that is mixed with the order data for signing.
    /// This is done in order to avoid chain and domain replay protection, so
    /// that signed orders are only valid for specific GPv2 contracts.
    ///
    /// The replay protection is defined as the Keccak-256 hash of `"GPv2"`
    /// followed by the chain ID and finally the contract address.
    bytes32 public immutable replayProtection;

    address private immutable WETH;

    /// @dev The Uniswap factory. This is used as the AMM that GPv2 settles with
    /// and is responsible for determining the range of the settlement price as
    /// well as trading surplus that cannot be directly settled in a batch.
    IUniswapV2Factory public immutable uniswapFactory;

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
    }

    struct Trade {
        uint256 sellAmount;
        uint256 buyAmount;
        address sellToken;
        address buyToken;
    }

    /// @param uniswapFactory_ The Uniswap factory to act as the AMM for this
    /// GPv2 settlement contract.
    constructor(IUniswapV2Factory uniswapFactory_, address _WETH) public {
        uint256 chainId;
        WETH = _WETH;

        // NOTE: Currently, the only way to get the chain ID in solidity is
        // using assembly.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            chainId := chainid()
        }

        replayProtection = keccak256(
            abi.encode(DOMAIN_SEPARATOR, chainId, address(this))
        );
        uniswapFactory = uniswapFactory_;
    }

    function settle(
        bytes calldata encodedTrades,
        uint256[] memory clearingPrices,
        address[] memory tokens,
        bytes calldata encodedOrders
    ) external {
        uint256[] memory initialBalances = generateInitialBalances(tokens);
        Order[] memory orders = decodeOrders(encodedOrders);
        receiveTradeAmounts(orders);
        //todo: replay protection orders

        Trade[] memory trades = decodeTrades(encodedTrades);
        uint256[] memory negativeFees = executeTrades(trades, tokens);
        //todo: prevent several orders in the same direction

        verifyPrices(orders, clearingPrices, tokens, trades);

        uint256[] memory fees = settleOrders(orders, clearingPrices, tokens);

        checkFeeCollection(fees, negativeFees, tokens, initialBalances);
    }

    function executeTrades(Trade[] memory trades, address[] memory tokens)
        internal
        returns (uint256[] memory)
    {
        uint256[] memory negativeFees = new uint256[](tokens.length);
        // execute trades against uniswap...
        for (uint256 i = 0; i < trades.length; i++) {
            IUniswapV2Pair uniswapPool = uniswapPairAddress(
                IERC20(trades[i].sellToken),
                IERC20(trades[i].buyToken)
            );
            require(
                IERC20(trades[i].sellToken).transfer(
                    address(uniswapPool),
                    trades[i].sellAmount
                ),
                "transfer to uniswap failed"
            );
            if (trades[i].sellToken == uniswapPool.token0()) {
                uniswapPool.swap(0, trades[i].buyAmount, address(this), "");
            } else {
                uniswapPool.swap(trades[i].buyAmount, 0, address(this), "");
            }
            negativeFees[findTokenIndex(trades[i].sellToken, tokens)] +=
                (trades[i].sellAmount * 3) /
                1000;
        }
        return negativeFees;
    }

    function verifyPrices(
        Order[] memory orders,
        uint256[] memory clearingPrices,
        address[] memory tokens,
        Trade[] memory trades
    ) public view {
        for (uint256 i = 0; i < orders.length; i++) {
            (uint256 uniPriceDen, uint256 uniPriceNum) = getUniswapPrice(
                orders[i].sellToken,
                orders[i].buyToken
            );
            (
                uint256 uniEffectivePriceDen,
                uint256 uniEffectivePriceNum
            ) = getUniswapEffectivePrice(
                orders[i].sellToken,
                orders[i].buyToken,
                trades
            );
            (
                uint256 clearingPriceDen,
                uint256 clearingPriceNum
            ) = getClearingPrice(
                orders[i].sellToken,
                orders[i].buyToken,
                clearingPrices,
                tokens
            );
            bool clearingPriceInUniswapBand = ((clearingPriceNum *
                uniPriceDen *
                997) /
                999 <=
                uniPriceNum * clearingPriceDen ||
                (clearingPriceNum * uniPriceDen * 997) / 999 <=
                uniPriceNum * clearingPriceNum);
            bool clearingPriceInEffetiveUniswapBand = uniEffectivePriceDen >
                0 &&
                uniEffectivePriceNum > 0 &&
                ((clearingPriceNum * uniEffectivePriceDen * 999) / 1000 <=
                    uniEffectivePriceNum * clearingPriceDen ||
                    (clearingPriceNum * uniEffectivePriceDen * 997) / 1000 >=
                    uniEffectivePriceNum * clearingPriceDen);
            require(
                clearingPriceInUniswapBand ||
                    clearingPriceInEffetiveUniswapBand,
                "price is not acceptable"
            );
        }
    }

    function getUniswapPrice(address sellToken, address buyToken)
        internal
        view
        returns (uint256, uint256)
    {
        // calculate prices via WETH pair
        if (sellToken == WETH || buyToken == WETH) {
            IUniswapV2Pair uniswapPool = uniswapPairAddress(
                IERC20(sellToken),
                IERC20(buyToken)
            );
            (uint112 reserve0, uint112 reserve1, ) = uniswapPool.getReserves();
            if (sellToken == uniswapPool.token0()) {
                return (uint256(reserve0), uint256(reserve1));
            } else {
                return (uint256(reserve1), uint256(reserve0));
            }
        } else {
            //unimplemented! consider hop over WETH
            return (1, 1);
        }
    }

    function getUniswapEffectivePrice(
        address sellToken,
        address buyToken,
        Trade[] memory trades
    ) internal pure returns (uint256, uint256) {
        // todo: binary search for finding/checking the effective prices,
        // if we assume more than 5 trades.
        for (uint256 i = 0; i < trades.length; i++) {
            if (
                trades[i].sellToken == sellToken &&
                trades[i].buyToken == buyToken
            ) {
                return (trades[i].sellAmount, trades[i].buyAmount);
            } else if (
                trades[i].sellToken == buyToken &&
                trades[i].buyToken == sellToken
            ) {
                return (trades[i].buyAmount, trades[i].sellAmount);
            }
        }
        return (0, 0);
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

    function generateInitialBalances(address[] memory tokens)
        public
        view
        returns (uint256[] memory)
    {
        uint256[] memory initialBalances = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            initialBalances[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        return initialBalances;
    }

    function checkFeeCollection(
        uint256[] memory fees,
        uint256[] memory negativeFees,
        address[] memory tokens,
        uint256[] memory initialBalances
    ) public view {
        for (uint256 i = 0; i < fees.length; i++) {
            require(
                fees[i].add(initialBalances[i]).sub(negativeFees[i]) >
                    IERC20(tokens[i]).balanceOf(address(this)),
                "not sufficient fees collected"
            );
        }
    }

    function decodeSingleOrder(bytes calldata orderBytes)
        internal
        pure
        returns (Order memory orders)
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
                nonce
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
                nonce: nonce
            });
    }

    function decodeSingleTrade(bytes calldata tradeBytes)
        internal
        pure
        returns (Trade memory trade)
    {
        (
            uint256 sellAmount,
            uint256 buyAmount,
            address sellToken,
            address buyToken
        ) = abi.decode(tradeBytes, (uint256, uint256, address, address));

        return
            Trade({
                sellAmount: sellAmount,
                buyAmount: buyAmount,
                buyToken: buyToken,
                sellToken: sellToken
            });
    }

    function decodeTrades(bytes calldata tradeBytes)
        internal
        pure
        returns (Trade[] memory trades)
    {
        require(
            tradeBytes.length % TRADE_STRIDE == 0,
            "malformed encoded trades"
        );
        trades = new Trade[](trades.length / TRADE_STRIDE);
        uint256 count = 0;
        while (trades.length > 0) {
            bytes calldata singleTrade = tradeBytes[:TRADE_STRIDE];
            tradeBytes = tradeBytes[TRADE_STRIDE:];
            trades[count] = decodeSingleTrade(singleTrade);
            count = count + 1;
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

    function receiveTradeAmounts(Order[] memory orders) internal {
        for (uint256 i = 0; i < orders.length; i++) {
            require(
                IERC20(orders[i].sellToken).transferFrom(
                    orders[i].owner,
                    address(this),
                    orders[i].sellAmount
                ),
                "order transfer failed"
            );
        }
    }

    function settleOrders(
        Order[] memory orders,
        uint256[] memory clearingPrices,
        address[] memory tokens
    ) internal returns (uint256[] memory) {
        uint256[] memory collectedFees = new uint256[](tokens.length);

        for (uint256 i = 0; i < orders.length; i++) {
            uint256 soldAmount = (orders[i].executedAmount * 999) / 1000;
            uint256 sellTokenIndex = findTokenIndex(orders[i].buyToken, tokens);
            collectedFees[sellTokenIndex] += orders[i].executedAmount / 1000;
            uint256 amountReceived = soldAmount
                .mul(clearingPrices[sellTokenIndex])
                .div(
                clearingPrices[findTokenIndex(orders[i].sellToken, tokens)]
            );
            require(
                IERC20(orders[i].buyToken).transfer(
                    orders[i].owner,
                    amountReceived
                ),
                "settlement transfer failed"
            );
        }
        return collectedFees;
    }

    /// @dev Returns a unique pair address for the specified tokens. Note that
    /// the tokens must be in lexicographical order or else this call reverts.
    /// This is required to ensure that the `token0` and `token1` are in the
    /// same order as the Uniswap pair.
    /// @param token0 The address one token in the pair.
    /// @param token1 The address the other token in the pair.
    /// @return The address of the Uniswap token pair.
    function uniswapPairAddress(IERC20 token0, IERC20 token1)
        public
        view
        returns (IUniswapV2Pair)
    {
        require(
            address(token0) != address(0) && address(token0) < address(token1),
            "invalid pair"
        );

        // NOTE: The address of a Uniswap pair is deterministic as it is created
        // with `CREATE2` instruction. This allows us get the pair address
        // without requesting any chain data!
        // See <https://uniswap.org/docs/v2/smart-contract-integration/getting-pair-addresses/>.
        bytes32 pairAddressBytes = keccak256(
            abi.encodePacked(
                hex"ff",
                address(uniswapFactory),
                keccak256(abi.encodePacked(address(token0), address(token1))),
                hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
            )
        );
        return IUniswapV2Pair(uint256(pairAddressBytes));
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
