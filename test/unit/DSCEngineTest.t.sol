// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    address public USER = makeAddr("USER");

    DeployDSC deployer;
    DecentralizedStableCoin public dsc;
    DSCEngine public dscEngine;
    HelperConfig helperConfig;

    address public wethUsdPriceFeed;
    address public wbtcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (wethUsdPriceFeed, wbtcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

     ///////////////////////////
    // Construction tests /////
    //////////////////////////

    // Test: Test that the length of the tokenAddress and priceFeeds are equal
    function testPriceFeedAndTokenLength() public {
        
    }


    ////////////////////
    // Price tests /////
    ////////////////////

    // Test: get value of tokens in usd, this is using the chainlink price feeds
    function testGetUsdValue() public {
        // 15 alone would have meant 15 wei
        uint256 ethAmountToBuy = 15e18;

        // 1 ETH = $2000
        uint256 expectedUsdValue = 2000 * ethAmountToBuy;

        uint256 usdValue = dscEngine.getUsdValue(weth, ethAmountToBuy);
        console.log(usdValue);
        assertEq(usdValue, expectedUsdValue);
    }

    // Test: deposit collateral tests
    function testRevertIfCollateralIsZero() public {
        vm.prank(USER);

        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedToBeHigherThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
    }
}
