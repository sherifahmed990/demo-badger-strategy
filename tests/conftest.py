from brownie import (
    accounts,
    interface,
    Controller,
    SettV4,
    MyStrategy,
)
from config import (
    BADGER_DEV_MULTISIG,
    POOL,
    TOKEN0,
    TOKEN1,
    FEES,
    PROTOCOL_FEE,
    MAX_TOTAL_SUPPLY
)
from dotmap import DotMap
import pytest


@pytest.fixture
def deployed():
    """
    Deploys, vault, controller and strats and wires them up for you to test
    """
    deployer = accounts[0]

    strategist = deployer
    keeper = deployer
    guardian = deployer

    governance = accounts.at(BADGER_DEV_MULTISIG, force=True)

    controller = Controller.deploy({"from": deployer})
    controller.initialize(BADGER_DEV_MULTISIG, strategist, keeper, BADGER_DEV_MULTISIG)

    sett = SettV4.deploy({"from": deployer})
    sett.initialize(
        controller,
        BADGER_DEV_MULTISIG,
        keeper,
        guardian,
        False,
        "prefix",
        "PREFIX",
        POOL,
        PROTOCOL_FEE,
        MAX_TOTAL_SUPPLY
    )

    sett.unpause({"from": governance})
    controller.setVault((TOKEN0), sett)

    ## TODO: Add guest list once we find compatible, tested, contract
    # guestList = VipCappedGuestListWrapperUpgradeable.deploy({"from": deployer})
    # guestList.initialize(sett, {"from": deployer})
    # guestList.setGuests([deployer], [True])
    # guestList.setUserDepositCap(100000000)
    # sett.setGuestList(guestList, {"from": governance})

    ## Start up Strategy
    strategy = MyStrategy.deploy({"from": deployer})
    strategy.initialize(
        BADGER_DEV_MULTISIG,
        strategist,
        controller,
        keeper,
        guardian,        
        sett.address,
        FEES
    )

    ## Tool that verifies bytecode (run independently) <- Webapp for anyone to verify

    ## Set up tokens
    token0 = interface.IERC20(TOKEN0)
    token1 = interface.IERC20(TOKEN1)

    ## Wire up Controller to Strart
    ## In testing will pass, but on live it will fail
    controller.approveStrategy(TOKEN0, strategy, {"from": governance})
    controller.approveStrategy(TOKEN1, strategy, {"from": governance})
    controller.setStrategy(TOKEN0, strategy, {"from": deployer})
    controller.setStrategy(TOKEN1, strategy, {"from": deployer})

    ## Uniswap some tokens here
    router = interface.IUniswapRouterV2("0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D")
    router.swapExactETHForTokens(
        0,  ## Mint out
        ["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", TOKEN0],
        deployer,
        9999999999999999,
        {"from": deployer, "value": 5000000000000000000},
    )

    router.swapExactETHForTokens(
        0,  ## Mint out
        ["0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", TOKEN1],
        deployer,
        9999999999999999,
        {"from": deployer, "value": 5000000000000000000},
    )

    return DotMap(
        deployer=deployer,
        controller=controller,
        vault=sett,
        sett=sett,
        strategy=strategy,
        token0=token0,
        token1=token1,
        # guestList=guestList,
        #want=want,
        #lpComponent=lpComponent,
        #rewardToken=rewardToken,
    )


## Contracts ##


@pytest.fixture
def vault(deployed):
    return deployed.vault


@pytest.fixture
def sett(deployed):
    return deployed.sett


@pytest.fixture
def controller(deployed):
    return deployed.controller


@pytest.fixture
def strategy(deployed):
    return deployed.strategy


## Tokens ##


@pytest.fixture
def token0(deployed):
    return deployed.token0

@pytest.fixture
def token1(deployed):
    return deployed.token1


@pytest.fixture
def tokens():
    return [WANT, LP_COMPONENT, REWARD_TOKEN]


## Accounts ##


@pytest.fixture
def deployer(deployed):
    return deployed.deployer


@pytest.fixture
def strategist(strategy):
    return accounts.at(strategy.strategist(), force=True)


@pytest.fixture
def settKeeper(vault):
    return accounts.at(vault.keeper(), force=True)


@pytest.fixture
def strategyKeeper(strategy):
    return accounts.at(strategy.keeper(), force=True)

## Forces reset before each test
@pytest.fixture(autouse=True)
def isolation(fn_isolation):
    pass
