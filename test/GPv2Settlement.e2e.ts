import ERC20 from "@openzeppelin/contracts/build/contracts/ERC20PresetMinterPauser.json";
import { expect } from "chai";
import { BigNumber, Contract, TypedDataDomain, Wallet } from "ethers";
import { ethers, waffle } from "hardhat";

import {
  Order,
  OrderKind,
  SettlementEncoder,
  SigningScheme,
  allowanceManagerAddress,
  domain,
} from "../src/ts";

describe("GPv2Settlement: End to End Tests", () => {
  const [deployer, owner, solver, ...traders] = waffle.provider.getWallets();

  let settlement: Contract;
  let allowanceManager: Contract;
  let domainSeparator: TypedDataDomain;

  beforeEach(async () => {
    const GPv2AllowListAuthentication = await ethers.getContractFactory(
      "GPv2AllowListAuthentication",
      deployer,
    );
    const authenticator = await GPv2AllowListAuthentication.deploy(
      owner.address,
    );
    await authenticator.connect(owner).addSolver(solver.address);

    const GPv2Settlement = await ethers.getContractFactory(
      "GPv2Settlement",
      deployer,
    );
    settlement = await GPv2Settlement.deploy(authenticator.address);
    allowanceManager = await ethers.getContractAt(
      "GPv2AllowanceManager",
      allowanceManagerAddress(settlement.address),
    );

    const { chainId } = await ethers.provider.getNetwork();
    domainSeparator = domain(chainId, settlement.address);
  });

  it("should settle red wine and olive oil market", async () => {
    const STARTING_BALANCE = ethers.utils.parseEther("1000.0");
    const erc20 = (symbol: string) =>
      waffle.deployContract(deployer, ERC20, [symbol, 18]);

    const eur = await erc20("EUR");
    const oil = await erc20("OIL");
    const wine = await erc20("RED");

    const orderDefaults = {
      validTo: 0xffffffff,
      feeAmount: ethers.utils.parseEther("1.0"),
    };
    const encoder = new SettlementEncoder(domainSeparator);

    const addOrder = async (
      trader: Wallet,
      order: Order,
      executedAmount: BigNumber,
    ) => {
      const sellToken = await ethers.getContractAt(
        ERC20.abi,
        order.sellToken,
        deployer,
      );
      await sellToken.mint(trader.address, STARTING_BALANCE);
      await sellToken
        .connect(trader)
        .approve(allowanceManager.address, ethers.constants.MaxUint256);

      await encoder.signEncodeTrade(
        order,
        executedAmount,
        trader,
        SigningScheme.TYPED_DATA,
      );
    };

    await addOrder(
      traders[0],
      {
        ...orderDefaults,
        kind: OrderKind.SELL,
        partiallyFillable: false,
        sellToken: wine.address,
        buyToken: oil.address,
        sellAmount: ethers.utils.parseEther("12.0"),
        buyAmount: ethers.utils.parseEther("12.0"),
        appData: 1,
      },
      ethers.constants.Zero,
    );

    await addOrder(
      traders[1],
      {
        ...orderDefaults,
        kind: OrderKind.SELL,
        partiallyFillable: false,
        sellToken: oil.address,
        buyToken: eur.address,
        sellAmount: ethers.utils.parseEther("15.0"),
        buyAmount: ethers.utils.parseEther("180.0"),
        appData: 4,
      },
      ethers.constants.Zero,
    );

    await addOrder(
      traders[2],
      {
        ...orderDefaults,
        kind: OrderKind.BUY,
        partiallyFillable: true,
        buyToken: oil.address,
        sellToken: eur.address,
        buyAmount: ethers.utils.parseEther("4.0"),
        sellAmount: ethers.utils.parseEther("52.0"),
        appData: 5,
      },
      ethers.utils.parseEther("27.0").div(13),
    );

    await addOrder(
      traders[3],
      {
        ...orderDefaults,
        kind: OrderKind.BUY,
        partiallyFillable: true,
        buyToken: wine.address,
        sellToken: eur.address,
        buyAmount: ethers.utils.parseEther("20.0"),
        sellAmount: ethers.utils.parseEther("280.0"),
        appData: 6,
      },
      ethers.utils.parseEther("12.0"),
    );

    await settlement.connect(solver).settle(
      encoder.tokens,
      encoder.clearingPrices({
        [eur.address]: ethers.utils.parseEther("1.0"),
        [oil.address]: ethers.utils.parseEther("13.0"),
        [wine.address]: ethers.utils.parseEther("14.0"),
      }),
      encoder.encodedTrades,
      "0x",
      "0x",
    );

    expect(await wine.balanceOf(traders[0].address)).to.deep.equal(
      STARTING_BALANCE.sub(ethers.utils.parseEther("12.0")).sub(
        orderDefaults.feeAmount,
      ),
    );
    expect(await oil.balanceOf(traders[0].address)).to.deep.equal(
      ethers.utils.parseEther("12.0").mul(14).div(13),
    );

    expect(await oil.balanceOf(traders[1].address)).to.deep.equal(
      STARTING_BALANCE.sub(ethers.utils.parseEther("15.0")).sub(
        orderDefaults.feeAmount,
      ),
    );
    expect(await eur.balanceOf(traders[1].address)).to.deep.equal(
      ethers.utils.parseEther("15.0").mul(13),
    );

    expect(await eur.balanceOf(traders[2].address)).to.deep.equal(
      STARTING_BALANCE.sub(ethers.utils.parseEther("27.0"))
        .sub(
          orderDefaults.feeAmount
            .mul(ethers.utils.parseEther("27.0").div(13))
            .div(ethers.utils.parseEther("4.0")),
        )
        // NOTE: Account for rounding error from computing sell amount that is
        // an order of magnitude larger than executed buy amount from the
        // settlement.
        .add(1),
    );
    expect(await oil.balanceOf(traders[2].address)).to.deep.equal(
      ethers.utils.parseEther("27.0").div(13),
    );

    expect(await eur.balanceOf(traders[3].address)).to.deep.equal(
      STARTING_BALANCE.sub(ethers.utils.parseEther("12.0").mul(14)).sub(
        orderDefaults.feeAmount
          .mul(ethers.utils.parseEther("12.0"))
          .div(ethers.utils.parseEther("20.0")),
      ),
    );
    expect(await wine.balanceOf(traders[3].address)).to.deep.equal(
      ethers.utils.parseEther("12.0"),
    );
  });
});
