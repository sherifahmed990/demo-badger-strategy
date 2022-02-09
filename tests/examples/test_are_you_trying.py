from brownie import *
from helpers.constants import MaxUint256


def test_are_you_trying(deployer, sett, strategy, token0, token1):
    """
    Verifies that you set up the Strategy properly
    """
    # Setup
    startingBalance0 = token0.balanceOf(deployer)
    startingBalance1 = token1.balanceOf(deployer)

    depositAmount0 = startingBalance0 // 2
    assert startingBalance0 >= depositAmount0
    assert startingBalance0 > 0

    depositAmount1 = startingBalance1 // 2
    assert startingBalance1 >= depositAmount1
    assert startingBalance1 > 0
    # End Setup

    print('Starting Balance0: ' + str(startingBalance0))
    print('Starting Balance1: ' + str(startingBalance1))
    # Deposit
    assert token0.balanceOf(sett) == 0
    assert token1.balanceOf(sett) == 0

    token0.approve(sett, MaxUint256, {"from": deployer})
    token1.approve(sett, MaxUint256, {"from": deployer})
    sett.deposit(depositAmount0, depositAmount1, {"from": deployer})

    available = sett.available()
    print('Sett Balance0: ' + str(available[0]))
    print('Sett Balance1: ' + str(available[1]))
    assert available[0] > 0
    assert available[1] > 0

    sett.earn({"from": deployer})

    #chain.sleep(10000 * 13)  # Mine so we get some interest

    ## TEST 1: Does the want get used in any way?
    assert token0.balanceOf(sett) == depositAmount0 - available[0]

    # Did the strategy do something with the asset?
    #assert token0.balanceOf(strategy) < available[0]

    # Use this if it should invest all
    # assert want.balanceOf(strategy) == 0

    # Change to this if the strat is supposed to hodl and do nothing
    # assert strategy.balanceOf(want) = depositAmount

    ## TEST 2: Is the Harvest profitable?
    harvest = strategy.harvest({"from": deployer})
    event = harvest.events["Harvest"]
    # If it doesn't print, we don't want it
    assert event["harvested"] > 0
