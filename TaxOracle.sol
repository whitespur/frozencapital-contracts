// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
  ____ ____    ___   ____  ____ __  __      ___  ___  ____  __ ______  ___  __
 ||    || \\  // \\    // ||    ||\ ||     //   // \\ || \\ || | || | // \\ ||
 ||==  ||_// ((   ))  //  ||==  ||\\||    ((    ||=|| ||_// ||   ||   ||=|| ||
 ||    || \\  \\_//  //__ ||___ || \||     \\__ || || ||    ||   ||   || || ||__|

    https://frozen.capital
*/
contract FrostTaxOracle is Ownable {
    using SafeMath for uint256;

    IERC20 public frost;
    IERC20 public wavax;
    address public pair;

    constructor(
        address _frost,
        address _wavax,
        address _pair
    ) public {
        require(_frost != address(0), "frost address cannot be 0");
        require(_wavax != address(0), "wavax address cannot be 0");
        require(_pair != address(0), "pair address cannot be 0");
        frost = IERC20(_frost);
        wavax = IERC20(_wavax);
        pair = _pair;
    }

    function consult(address _token, uint256 _amountIn) external view returns (uint144 amountOut) {
        require(_token == address(frost), "token needs to be frost");
        uint256 frostBalance = frost.balanceOf(pair);
        uint256 wavaxBalance = wavax.balanceOf(pair);
        return uint144(frostBalance.div(wavaxBalance));
    }

    function setFrost(address _frost) external onlyOwner {
        require(_frost != address(0), "frost address cannot be 0");
        frost = IERC20(_frost);
    }

    function setWavax(address _wavax) external onlyOwner {
        require(_wavax != address(0), "wavax address cannot be 0");
        wavax = IERC20(_wavax);
    }

    function setPair(address _pair) external onlyOwner {
        require(_pair != address(0), "pair address cannot be 0");
        pair = _pair;
    }



}
