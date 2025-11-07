// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// Simple mock factory that allows mapping two tokens to a pair address.
/// KipuBankV3 only calls factory.getPair(token, USDC) so basta con devolver una dirección != 0.
contract MockUniswapFactoryMock {
    mapping(bytes32 => address) public pairs;
    address public owner;

    event PairSet(address indexed tokenA, address indexed tokenB, address pair);

    constructor() {
        owner = msg.sender;
    }

    function setPair(address tokenA, address tokenB, address pair) external {
        require(msg.sender == owner, "only owner");
        bytes32 k = _key(tokenA, tokenB);
        pairs[k] = pair;
        emit PairSet(tokenA, tokenB, pair);
    }

    function getPair(address tokenA, address tokenB) external view returns (address) {
        return pairs[_key(tokenA, tokenB)];
    }

    function _key(address a, address b) internal pure returns (bytes32) {
        // keep order-agnostic (optional)
        if (a < b) return keccak256(abi.encodePacked(a, b));
        return keccak256(abi.encodePacked(b, a));
    }
}