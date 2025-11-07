// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockUniswapRouterMock {
    address public immutable factoryAddr;
    address public immutable wethAddr;

    constructor(address _factory, address _weth) {
        factoryAddr = _factory;
        wethAddr = _weth;
    }

    function factory() external view returns (address) {
        return factoryAddr;
    }

    function WETH() external view returns (address) {
        return wethAddr;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external pure returns (uint256[] memory amounts) {
        require(path.length >= 2, "invalid path");
        amounts = new uint256[](path.length);
        for (uint256 i = 0; i < path.length; i++) {
            amounts[i] = amountIn;
        }
        return amounts;
    }

    /// Enhanced swap: try to mint output token to `to` if mint exists, otherwise transfer from router balance.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin */,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        // take input token via transferFrom from msg.sender (KipuBank contract)
        IERC20Minimal(path[0]).transferFrom(msg.sender, address(this), amountIn);

        // Try to mint the output token to `to` if the token supports mint(address,uint256)
        address outToken = path[path.length - 1];
        bool minted = false;
        // low-level call to mint(to, amountIn)
        (bool okMint, ) = outToken.call(abi.encodeWithSignature("mint(address,uint256)", to, amountIn));
        if (okMint) {
            minted = true;
        } else {
            // fallback: try to transfer outToken from this router balance to `to`
            IERC20Minimal(outToken).transfer(to, amountIn);
        }

        amounts = new uint256[](path.length);
        for (uint256 i = 0; i < path.length; i++) amounts[i] = amountIn;
        return amounts;
    }

    receive() external payable {}

    function swapExactETHForTokens(
        uint256 /* amountOutMin */,
        address[] calldata /* path */,
        address to,
        uint256 /* deadline */
    ) external payable returns (uint256[] memory amounts) {
        uint256 amount = msg.value;
        // If the output token in your path has mint, you could mint here too in an enhanced mock.
        amounts = new uint256[](2);
        amounts[0] = amount;
        amounts[1] = amount;
        return amounts;
    }
}