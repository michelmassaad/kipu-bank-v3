// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/KipuBankV3.sol";

// Mocks
import "./mocks/MockERC20.sol";
import "./mocks/MockAggregator.sol";
import "./mocks/MockUniswapV2Router.sol";

contract KipuBankV3Test is Test {
    KipuBankV3 public kipuBank;

    // Prefer real addresses if using fork
    address public ROUTER = 0xC53211616719c136A9a8075aEe7C5482A188AE50;
    address public WETH   = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14;
    address public USDC_ADDR = 0x1c7D4B196cB0c7b01D743FBC6330e9f9E1Eca96f;
    address public PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    address public user1 = makeAddr("user1");

    uint256 public constant BANK_CAP = 1_000_000 * 1e6;

    // Mock references
    MockERC20 internal mockUsdc;
    MockAggregator internal mockOracle;
    MockUniswapV2Router02 internal mockRouter;

    function setUp() public {
        string memory rpc = vm.envString("RPC_URL");
        if (bytes(rpc).length > 0) {
            vm.createSelectFork(rpc);
        }

        // ========== 1) USDC ==========
        if (USDC_ADDR.code.length == 0) {
            mockUsdc = new MockERC20("Mock USDC", "mUSDC", 6);
            mockUsdc.mint(address(this), 5_000_000 * 1e6);
            USDC_ADDR = address(mockUsdc);
        }

        // ========== 2) Chainlink Oracle ==========
        if (PRICE_FEED.code.length == 0) {
            mockOracle = new MockAggregator();
            mockOracle.setLatestAnswer(2_000 * 1e8); // $2000
            PRICE_FEED = address(mockOracle);
        }

        // ========== 3) Router ==========
        if (ROUTER.code.length == 0) {
            mockRouter = new MockUniswapV2Router02(WETH, USDC_ADDR);
            ROUTER = address(mockRouter);

            // Router debe tener USDC para swaps
            if (address(mockUsdc) != address(0)) {
                mockUsdc.mint(ROUTER, 2_000_000 * 1e6);
            }
        }

        // ========== 4) Deploy Banco ==========
        kipuBank = new KipuBankV3(
            PRICE_FEED,
            USDC_ADDR,
            BANK_CAP,
            ROUTER,
            WETH
        );

        // ========== 5) Fondos ==========
        vm.deal(user1, 10 ether);

        if (address(mockUsdc) != address(0)) {
            mockUsdc.mint(user1, 1_000 * 1e6);
        }

        vm.startPrank(user1);
        IERC20(USDC_ADDR).approve(address(kipuBank), type(uint256).max);
        vm.stopPrank();
    }

    /* ---------- TESTS ---------- */

    function test_DepositUSDC() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(user1);
        kipuBank.depositUsdc(amount);
        vm.stopPrank();

        assertEq(kipuBank.getBalance(user1), amount);
        assertEq(kipuBank.totalUsdcDeposited(), amount);
    }

    function test_DepositNativeEth() public {
        vm.prank(user1);
        kipuBank.depositNativeEth{value: 1 ether}(0);

        uint256 bal = kipuBank.getBalance(user1);

        assertTrue(bal > 0, "ETH USDC debe dar saldo > 0");
    }

    function test_WithdrawUSDC() public {
        uint256 amount = 100 * 1e6;

        vm.startPrank(user1);
        kipuBank.depositUsdc(amount);
        kipuBank.withdrawUsdc(amount);
        vm.stopPrank();

        assertEq(kipuBank.getBalance(user1), 0);
        assertEq(kipuBank.totalUsdcDeposited(), 0);
    }

    function test_Fail_BankCapExceeded_Eth() public {
        MockAggregator high = new MockAggregator();
        high.setLatestAnswer(int256(3_000_000_000 * 1e8));

        KipuBankV3 fakeBank = new KipuBankV3(
            address(high),
            USDC_ADDR,
            BANK_CAP,
            ROUTER,
            WETH
        );

        vm.expectRevert(KipuBankV3.BankCapExceeded.selector);
        vm.prank(user1);
        fakeBank.depositNativeEth{value: 1 ether}(0);
    }

    function test_Fail_BankCapExceeded_USDC() public {
        uint256 tooBig = BANK_CAP + 1e6;
        if (address(mockUsdc) != address(0)) {
            mockUsdc.mint(user1, tooBig);
        }

        vm.startPrank(user1);
        IERC20(USDC_ADDR).approve(address(kipuBank), tooBig);
        vm.expectRevert(KipuBankV3.BankCapExceeded.selector);
        kipuBank.depositUsdc(tooBig);
        vm.stopPrank();
    }
}
