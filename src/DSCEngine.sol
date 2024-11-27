// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author Marvelous Afolabi
 * The system is designed to be as minimal as possible and have the tokens maintain a $1 == 1 token peg
 * The   stablecoin has the below properties
 * Exogenic
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 *
 * Our DSC system should alwaus be "overcollateralized". At no point should the value of
 *     all collateral <= the $ backed value of all the DSC.
 *
 * It is similar to DAI if dai has no fees, no governance, and was only backed by WETH and WBTC
 *
 * @notice This contract is the core of the DSC system. It handles all the logic for minting and redeeming
 *     DSC, as well as depositing and withdrawing collateral
 *
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system
 */
contract DSCEngine is ReentrancyGuard {
    // Errors
    error DSCEngine__NeedToBeHigherThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressMustBeTheSameLenght();
    error DSCEngine__TokenNotAllowedAsCollateral();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor();
    error DSCEngine__MintFailed();
    error DSCEngine__UserIsNotAtRiskOfLiquidation();
    error DSCEngine__HealthFactorNotImproved();

    // State variables
    uint256 private constant COLLATERAL_PERCENTAGE = 150;
    uint256 private constant COLLATERAL_DIVISOR = 100;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    // Think of it as a rule saying only 50% of you collateral is counted for safety purposes. ie It's like saying only if you have $100, I only trust 50% of it to cover your debt.
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100; // This helps keep the math clear and precise. Like dividing percentages.
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant BONUS_PERCENTAGE = 10;
    uint256 private constant BONUS_PRECISION = 100;

    mapping(address token => address priceFeed) private s_priceFeeds;

    // Reason for the nexted mapping is because multiple tokens (with different balances) can be associated to a single user
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 dscTokenMinted) private s_userToDscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    // Events
    event CollateralDeposited(
        address indexed user, address indexed collateralAddress, uint256 indexed collateralAmount
    );

    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed collateralToken, uint256 amount
    );
    event DSCBurned(address indexed user, uint256 indexed dscAmount);

    // Modifiers
    modifier MoreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedToBeHigherThanZero();
        }
        _;
    }

    modifier isAllowedToken(address tokenAllowed) {
        if (s_priceFeeds[tokenAllowed] == address(0)) {
            revert DSCEngine__TokenNotAllowedAsCollateral();
        }
        _;
    }

    // External Functions
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressMustBeTheSameLenght();
        }

        // Here we set up the tokenAddresses to match the priceFeed (BTC/USD) (ETH/USD).

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            // s_priceFeeds[ETH] = ETH/USD
            // So that when we pass ETH into s_priceFeeds, we can get the priceFeed for ETH/USD.
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /////////////////////
    //Public Functions//
    ////////////////////

    /**
     * @notice follows CEI (Check, Effect, Interactions)
     * @notice this function will deposit your collateral and mint DSC in one transaction
     * @param tokenCollateralAddress The address of the collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param amountDscToMint The amount of DSC to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 collateralAmount,
        uint256 amountDscToMint
    ) public {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDSC(amountDscToMint);
    }

    /**
     * @notice follows CEI (Check, Effect, Interactions)
     * @param tokenCollateralAddress The address of the collateral
     * @param collateralAmount The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        MoreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        // internal record keeping
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += collateralAmount;

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
    }

    /**
     * @notice follows CEI (Check, Effect, Interactions)
     * @param dscAmountToMint The address of the collateral
     * @notice amount to mint must not exceed the users collateral.
     */
    function mintDSC(uint256 dscAmountToMint) public MoreThanZero(dscAmountToMint) nonReentrant {
        s_userToDscMinted[msg.sender] += dscAmountToMint;
        // If they minted too muc DSC that what is allowed due to their collateral, then revert.
        _revertIfHealthFactorIsBroken(msg.sender);

        // Actual minting
        bool minted = i_dsc.mint(msg.sender, dscAmountToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // To redeem your collateral
    // 1. Your collateral token balance must be reduced by the amiunt you want to withdr
    // 2. Your collateral would now be transferred to your wallet
    // 3. We check health factor after collateral is redeemed

    /**
     * @notice follows CEI (Check, Effect, Interactions)
     * @notice this function will burn dsc and redeem your collateral in one transaction
     * @param tokenCollateralAddress The address of the collateral
     * @param amountToRedeem The amount of collateral to redeem
     * @param amountToBurn The amount of DSC to burn
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountToRedeem, uint256 amountToBurn)
        public
    {
        burnDSC(amountToBurn);
        redeemCollateral(tokenCollateralAddress, amountToRedeem);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountToRedeem)
        public
        MoreThanZero(amountToRedeem)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountToRedeem, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amountToBurn) public MoreThanZero(amountToBurn) {
        _burnDSC(msg.sender, msg.sender, amountToBurn);
        _revertIfHealthFactorIsBroken(msg.sender); // Not necessary I think, might never hit this line.
    }

    /**
     * @param user The user to liquidate. This user must have broken the health factor. Their health factor should be beloww the min health factor before
     * the can be liquidated.
     * @param collateralToken The token to liquidate
     * @param debtToCover The amount of debt (DSC) to burn to improve the users health factor
     * @notice you can patially liquidate a user
     * @notice Users get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollaterized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collaterized, then we wouldnt be able to incentivize the liquidators.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * Following the CEI (Check, Effect, Interactions)
     */
    function liquidate(address user, address collateralToken, uint256 debtToCover)
        public
        MoreThanZero(debtToCover)
        nonReentrant
    {
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__UserIsNotAtRiskOfLiquidation();
        }

        // We want to burn their DSC "debt" and take their collateral
        // Bad user: $140 ETH, $100 DSC
        // debtToCover = $100 DSC
        // $100 of DSC = ?? ETH (since we are going to pay in eth).
        // 0.05 eth
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralToken, debtToCover);

        // incentivize the liquidator by given them 10% of the amount the debt they cover.
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * BONUS_PERCENTAGE) / BONUS_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateralToken, totalCollateralToRedeem, user, msg.sender);

        // Burn the users dsc
        _burnDSC(user, msg.sender, debtToCover);

        uint256 userEndingHealthFactor = _healthFactor(user);
        if (userEndingHealthFactor <= userStartingHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Reverts if this operation breaks the liquidaors health factor
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////////////////////
    //Private and Internal View Functions//
    ///////////////////////////////////////

    /**
     * @dev Low-level internal function, do not call without checking the health factor first.
     * @param onBehalfOf The user whose debt "dsc" is to be burned
     * @param dscFrom The user who is repaying the dsc
     * @param amountDscToBurn The amount of DSC to burn.
     */
    function _burnDSC(address onBehalfOf, address dscFrom, uint256 amountDscToBurn) private {
        s_userToDscMinted[onBehalfOf] -= amountDscToBurn;
        emit DSCBurned(onBehalfOf, amountDscToBurn);
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, collateralAmount);

        bool success = IERC20(tokenCollateralAddress).transfer(to, collateralAmount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param user The user whose health factor is to be checked.
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated.
     */
    function _healthFactor(address user) private view returns (uint256) {
        // Total DSC minted
        // Total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION; // ((100 * 50) / 100)

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function _getAccountInformation(address user) private view returns (uint256, uint256) {
        uint256 totalDscMinted = s_userToDscMinted[user];

        uint256 collateralValueInUsd = getAccountCollateralValueInUSD(user);

        return (totalDscMinted, collateralValueInUsd);
    }

    // Checks if the user tries to mint dsc more than their collateral.
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor();
        }
    }

    ///////////////////////////////////////
    // Public and External View Functions//
    /////////////////////////////////////

    function getAccountCollateralValueInUSD(address user) public view returns (uint256 collateralValueInUSD) {
        // We can loop through all the collateral tokens, get the amount the user deposited and map it to the price to get the usd value.
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 collateralAmount = s_collateralDeposited[user][token];
            collateralValueInUSD += getUsdValue(token, collateralAmount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // if 1 ETH = $1000
        // The returned value from chainlink would be 1000 * 1e8
        // Amount is in wei (1e18). Hence both the price and amount needs to be of the same decimal
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
}
