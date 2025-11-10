// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/* =================================================================================================================
 *                                                      IMPORTS
 * ================================================================================================================= */

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IUniswapV2Router02 } from "v2-periphery/interfaces/IUniswapV2Router02.sol";
import { IWETH } from "v2-periphery/interfaces/IWETH.sol";
import { AggregatorV3Interface } from "chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/* =================================================================================================================
 *                                                       CONTRACT
 * ================================================================================================================= */

/**
 * @title KipuBankV3
 * @author Michel Massaad
 * @notice A DeFi bank that converts all deposits (ETH, ERC20) to USDC and
 * stores them, respecting a global USDC-denominated cap.
 * @dev Integrates Uniswap V2 for swaps and Chainlink for ETH deposit
 * cap pre-check.
 */
contract KipuBankV3 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =================================================================================================================
    //                                                      VARIABLES
    // =================================================================================================================


    // --- Immutables (Configuration) ---

    /// @notice The Chainlink ETH/USD price feed interface (8 decimals).
    AggregatorV3Interface public immutable PRICE_FEED;

    /// @notice The USDC token contract interface (6 decimals).
    IERC20 public immutable USDC;

    /// @notice The global deposit cap for the bank, denominated in USDC (6 decimals).
    uint256 public immutable BANK_CAP_USDC;

    /// @notice The Uniswap V2 Router interface.
    IUniswapV2Router02 public immutable UNISWAP_ROUTER;

    /// @notice The Wrapped ETH (WETH) contract interface.
    IWETH public immutable WETH;

    // --- Storage (Mutable State) ---

    /// @notice The total amount of USDC currently held by the bank.
    uint256 public totalUsdcDeposited;

    /// @notice Mapping from a user's address to their USDC balance.
    mapping(address => uint256) public balances;
    
    // =================================================================================================================
    //                                                       EVENTS
    // =================================================================================================================

    /**
     * @notice Emitted when a user's deposit is successfully processed and credited.
     * @param user The address of the depositor.
     * @param tokenIn The address of the asset being deposited (address(0) for ETH).
     * @param amountIn The amount of the asset deposited.
     * @param usdcReceived The amount of USDC credited to the user's balance.
     */
    event Deposit(
        address indexed user,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 usdcReceived
    );

    /**
     * @notice Emitted when a user successfully withdraws USDC.
     * @param user The address of the withdrawer.
     * @param amount The amount of USDC withdrawn.
     */
    event WithdrawalUsdc(address indexed user, uint256 amount);

    // =================================================================================================================
    //                                                      ERRORS
    // =================================================================================================================

    /// @notice Thrown when a deposit would cause the bank to exceed its cap.
    error BankCapExceeded();
    /// @notice Thrown when a user tries to withdraw more than their balance.
    error InsufficientBalance();
    /// @notice Thrown when a provided amount is 0.
    error InvalidAmount();
    /// @notice Thrown when a provided configuration address is address(0).
    error InvalidAddress();
    /// @notice Thrown when a swap executes but returns less than the minimum amount.
    error SlippageTooHigh();
    /// @notice Thrown if a user tries to deposit USDC via the `depositToken` function.
    error CannotDepositUsdcDirectly();

    // =================================================================================================================
    //                                                      MODIFIERS
    // =================================================================================================================

    /**
     * @notice Reverts if the provided amount is 0.
     * @param _amount The amount to check.
     */
    modifier nonZeroAmount(uint256 _amount) {
        _nonZeroAmount(_amount); // Calls the internal logic
        _;
    }

    // =================================================================================================================
    //                                                      CONSTRUCTOR
    // =================================================================================================================

    /**
     * @notice Initializes the contract with all necessary protocol addresses.
     * @param _priceFeedAddress The address of the Chainlink ETH/USD price feed.
     * @param _usdcTokenAddress The address of the USDC token.
     * @param _bankCapUsdc The total deposit cap for the bank, in USDC (6 decimals).
     * @param _routerAddress The address of the Uniswap V2 Router.
     * @param _wethAddress The address of the WETH contract.
     */
    constructor(
        address _priceFeedAddress,
        address _usdcTokenAddress,
        uint256 _bankCapUsdc,
        address _routerAddress,
        address _wethAddress
    ) Ownable(msg.sender) {
        if (
            _priceFeedAddress == address(0) ||
            _usdcTokenAddress == address(0) ||
            _routerAddress == address(0) ||
            _wethAddress == address(0)
        ) {
            revert InvalidAddress();
        }

        PRICE_FEED = AggregatorV3Interface(_priceFeedAddress);
        USDC = IERC20(_usdcTokenAddress);
        BANK_CAP_USDC = _bankCapUsdc;
        UNISWAP_ROUTER = IUniswapV2Router02(_routerAddress);
        WETH = IWETH(_wethAddress);
    }

    // =================================================================================================================
    //                                                   RECEIVE / FALLBACK
    // =================================================================================================================

    /**
     * @notice Rejects plain ETH transfers to force users to use the deposit functions.
     */
    receive() external payable {
        revert("Use depositNativeEth() to deposit ETH");
    }

    // =================================================================================================================
    //                                                 EXTERNAL FUNCTIONS
    // =================================================================================================================

    /**
     * @notice Deposits USDC tokens directly into the user's balance.
     * @dev Checks cap, updates state, and transfers tokens.
     * @param _amount The amount of USDC (6 decimals) to deposit.
     */
    function depositUsdc(uint256 _amount)
        external
        nonZeroAmount(_amount)
    {
        // 1. Checks
        _checkBankCap(_amount);

        // 2. Effects
        _creditUsdc(msg.sender, _amount);

        // 3. Interactions
        USDC.safeTransferFrom(msg.sender, address(this), _amount);
        emit Deposit(msg.sender, address(USDC), _amount, _amount);
    }

    /**
     * @notice Deposits native ETH, which is automatically swapped for USDC.
     * @dev Uses Chainlink oracle for cap check, then Uniswap for the swap.
     * @param _minUsdcOut The minimum amount of USDC (6 dec) the user will accept.
     */
    function depositNativeEth(uint256 _minUsdcOut)
        external
        payable
        nonReentrant
        nonZeroAmount(msg.value)
    {
        // 1. Checks (Uses Oracle)
        uint256 incomingUsdValue = getEthValueInUsd(msg.value);
        uint256 incomingUsdcEstimate = _getUsdcValueFromUsd(incomingUsdValue);
        _checkBankCap(incomingUsdcEstimate);

        // 2. Interactions (Swap)
        uint256 actualUsdcReceived = _swapEthToUsdc(_minUsdcOut);

        // 3. Effects (Credit)
        _creditUsdc(msg.sender, actualUsdcReceived);

        emit Deposit(
            msg.sender,
            address(0),
            msg.value,
            actualUsdcReceived
        );
    }

    /**
     * @notice Deposits an ERC20 token, which is automatically swapped for USDC.
     * @dev Uses a 3-step path (Token -> WETH -> USDC) for robust swaps.
     * @param _token The address of the ERC20 token to deposit.
     * @param _amount The amount of the token to deposit (in its own decimals).
     * @param _minUsdcOut The minimum amount of USDC (6 dec) the user will accept.
     */
    function depositToken(
        address _token,
        uint256 _amount,
        uint256 _minUsdcOut
    )
        external
        nonReentrant
        nonZeroAmount(_amount)
    {
        // 1. Checks
        if (_token == address(USDC)) revert CannotDepositUsdcDirectly();

        // Estimate output using 3-step path
        address[] memory path = new address[](3);
        path[0] = _token;
        path[1] = address(WETH);
        path[2] = address(USDC);

        uint256[] memory expectedAmounts = UNISWAP_ROUTER.getAmountsOut(
            _amount,
            path
        );
        uint256 expectedUsdc = expectedAmounts[2];
        _checkBankCap(expectedUsdc);

        // 2. Interactions (Transfer In + Swap)
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        
        uint256 actualUsdcReceived = _swapTokenToUsdc(
            _token,
            _amount,
            _minUsdcOut,
            path
        );

        // 3. Effects
        _creditUsdc(msg.sender, actualUsdcReceived);

        emit Deposit(
            msg.sender,
            _token,
            _amount,
            actualUsdcReceived
        );
    }

    /**
     * @notice Withdraws USDC from the user's bank balance.
     * @param _amount The amount of USDC (6 decimals) to withdraw.
     */
    function withdrawUsdc(uint256 _amount)
        external
        nonReentrant
        nonZeroAmount(_amount)
    {
        // 1. Checks
        uint256 currentUserUsdc = balances[msg.sender];
        if (_amount > currentUserUsdc) revert InsufficientBalance();

        // 2. Effects
        unchecked {
            balances[msg.sender] = currentUserUsdc - _amount;
            totalUsdcDeposited = totalUsdcDeposited - _amount;
        }

        // 3. Interactions
        USDC.safeTransfer(msg.sender, _amount);
        emit WithdrawalUsdc(msg.sender, _amount);
    }

   // =================================================================================================================
    //                                                  VIEW FUNCTIONS
    // =================================================================================================================

    /**
     * @notice Gets the USDC balance of a specific user.
     * @param _user The address of the user.
     * @return The user's balance in USDC (6 decimals).
     */
    function getBalance(address _user) external view returns (uint256) {
        return balances[_user];
    }

    /**
     * @notice Converts an ETH amount to its equivalent USD value via Chainlink.
     * @param _ethAmount Amount of ETH in wei (18 decimals).
     * @return Equivalent USD value with 8 decimal precision.
     */
    function getEthValueInUsd(uint256 _ethAmount)
        public
        view
        returns (uint256)
    {
        (, int256 price, , , ) = PRICE_FEED.latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint256(price) * _ethAmount) / 10**18;
    }

    // =================================================================================================================
    //                                                INTERNAL UTILITY FUNCTIONS
    // =================================================================================================================

    /**
     * @notice Internal check to see if a deposit would exceed the bank cap.
     * @param _amountUsdc The estimated USDC (6 dec) value of the incoming deposit.
     */
    function _checkBankCap(uint256 _amountUsdc) internal view {
        uint256 futureTotalUsdc = totalUsdcDeposited + _amountUsdc;
        if (futureTotalUsdc > BANK_CAP_USDC) {
            revert BankCapExceeded();
        }
    }

    /**
     * @notice Internal function to credit a user's balance and update total.
     * @dev This is the main "Effects" logic for all deposits.
     * @param _user The user to credit.
     * @param _amount The amount of USDC (6 dec) to credit.
     */
    function _creditUsdc(address _user, uint256 _amount) internal {
        uint256 currentTotal = totalUsdcDeposited;
        uint256 currentUserBalance = balances[_user];

        unchecked {
            totalUsdcDeposited = currentTotal + _amount;
            balances[_user] = currentUserBalance + _amount;
        }
    }

    /**
     * @notice Internal logic for the nonZeroAmount modifier.
     * @dev Saves gas by not inlining the check.
     */
    function _nonZeroAmount(uint256 _amount) internal pure {
        if (_amount == 0) revert InvalidAmount();
    }

    // =================================================================================================================
    //                                                 PRIVATE FUNCTIONS
    // =================================================================================================================


    /**
     * @notice Converts a USD value (8 dec) to a USDC value (6 dec).
     * @dev Assumes 1 USD = 1 USDC.
     * @param _usdAmount The USD value (8 decimals).
     * @return The USDC value (6 decimals).
     */
    function _getUsdcValueFromUsd(uint256 _usdAmount)
        private
        pure
        returns (uint256)
    {
        // 1 USD (1e8) / 100 = 1 USDC (1e6)
        return _usdAmount / (10**2);
    }

    // --- Helpers: Swaps (Interactions) ---

    /**
     * @notice Private helper to perform the ETH -> USDC swap.
     * @param _minUsdcOut The minimum USDC (6 dec) to receive.
     * @return actualUsdcReceived The actual USDC (6 dec) received from the swap.
     */
    function _swapEthToUsdc(uint256 _minUsdcOut)
        private
        returns (uint256 actualUsdcReceived)
    {
        address[] memory path = new address[](2);
        path[0] = address(WETH);
        path[1] = address(USDC);

        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));

        UNISWAP_ROUTER.swapExactETHForTokens{value: msg.value}(
            _minUsdcOut,
            path,
            address(this),
            block.timestamp
        );

        uint256 usdcBalanceAfter = USDC.balanceOf(address(this));
        actualUsdcReceived = usdcBalanceAfter - usdcBalanceBefore;

        if (actualUsdcReceived < _minUsdcOut) {
            revert SlippageTooHigh();
        }
    }

    /**
     * @notice Private helper to perform the Token -> USDC swap.
     * @dev Assumes the tokens are already held by this contract.
     * @param _token The address of the token to swap from.
     * @param _amount The amount of the token to swap.
     * @param _minUsdcOut The minimum USDC (6 dec) to receive.
     * @param path The pre-calculated swap path (e.g., TKN -> WETH -> USDC).
     * @return actualUsdcReceived The actual USDC (6 dec) received from the swap.
     */
    function _swapTokenToUsdc(
        address _token,
        uint256 _amount,
        uint256 _minUsdcOut,
        address[] memory path
    ) private returns (uint256 actualUsdcReceived) {
        
        // 1. Approve
        IERC20 tokenContract = IERC20(_token);
        tokenContract.safeIncreaseAllowance(address(UNISWAP_ROUTER), _amount);

        // 2. Measure balance BEFORE
        uint256 usdcBalanceBefore = USDC.balanceOf(address(this));

        // 3. Execute swap
        UNISWAP_ROUTER.swapExactTokensForTokens(
            _amount,
            _minUsdcOut,
            path,
            address(this),
            block.timestamp
        );

        // 4. Measure balance AFTER
        uint256 usdcBalanceAfter = USDC.balanceOf(address(this));
        actualUsdcReceived = usdcBalanceAfter - usdcBalanceBefore;

        // 5. Post-swap slippage check
        if (actualUsdcReceived < _minUsdcOut) {
            revert SlippageTooHigh();
        }

    }

}