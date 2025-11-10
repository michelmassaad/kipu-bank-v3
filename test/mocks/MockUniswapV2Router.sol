// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockUniswapV2Router02 {
    address private _weth;
    IERC20 public usdc;

    constructor(address weth_, address usdc_) {
        _weth = weth_;
        usdc = IERC20(usdc_);
    }

    // return the WETH address (igual firma a la real)
    function WETH() external view returns (address) {
        return _weth;
    }

    // Simula swapExactETHForTokens:
    // - calcula un output simple: 1 ETH -> 2000 USDC (ajusta si querés)
    // - transfiere USDC desde el router (este contrato) al 'to'
    function swapExactETHForTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable returns (uint[] memory amounts) {
        // Simple rule: price = 2000 USDC per ETH
        // msg.value is in wei (1e18). USDC has 6 decimals.
        uint256 out = (msg.value * 2000 * 1e6) / 1e18;

        // build amounts array similar a Uniswap (in tests se usa el último)
        amounts = new uint[](path.length);
        amounts[0] = msg.value;
        amounts[path.length - 1] = out;

        // transfer USDC from router's balance to recipient
        require(IERC20(address(usdc)).transfer(to, out), "MockRouter: USDC transfer failed");

        return amounts;
    }

    // Simula swapExactTokensForTokens (token -> usdc)
    function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external returns (uint[] memory amounts) {
        // For simplicity assume 1:1 at token -> USDC if token is not USDC, otherwise pass-through
        // In tests you will have pre-funded router, so just send amountOutMin or compute a fake rate.
        // We'll compute a naive estimate: amountOut = amountIn (not realistic, but sufficient for tests)
        uint256 out = amountIn;
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;

        require(IERC20(address(usdc)).transfer(to, out), "MockRouter: USDC transfer failed");
        return amounts;
    }

    // Simula getAmountsOut: devuelve un array con estimación
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        // Estimación: if path ends in USDC, make an approximate conversion:
        // assume 1 ETH in wei -> 2000 * 1e6 USDC (for tests only)
        if (path.length == 2) {
            // token -> USDC (if token is WETH simulate price)
            if (path[0] == _weth) {
                // amountIn is wei: convert to USDC 6dec
                uint256 out = (amountIn * 2000 * 1e6) / 1e18;
                amounts[1] = out;
            } else {
                // fallback 1:1
                amounts[1] = amountIn;
            }
        } else {
            // 3-step path: token -> WETH -> USDC -> naive fallback
            amounts[path.length - 1] = amountIn;
        }
        return amounts;
    }
}
