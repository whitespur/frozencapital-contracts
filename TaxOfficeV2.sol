// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "./owner/Operator.sol";
import "./interfaces/ITaxable.sol";
import "./interfaces/IUniswapV2Router.sol";
import "./interfaces/IERC20.sol";

/*
  ____ ____    ___   ____  ____ __  __      ___  ___  ____  __ ______  ___  __
 ||    || \\  // \\    // ||    ||\ ||     //   // \\ || \\ || | || | // \\ ||
 ||==  ||_// ((   ))  //  ||==  ||\\||    ((    ||=|| ||_// ||   ||   ||=|| ||
 ||    || \\  \\_//  //__ ||___ || \||     \\__ || || ||    ||   ||   || || ||__|

    https://frozen.capital
*/
contract TaxOfficeV2 is Operator {
    using SafeMath for uint256;

    // frost address will be here after deployment
    address public frost = address(0x320aDa89DbFA3A154613D2731c9BC3a4030DbA19);
    address public wavax = address(0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7);
    address public uniRouter = address(0x60aE616a2155Ee3d9A68541Ba4544862310933d4);

    mapping(address => bool) public taxExclusionEnabled;

    function setTaxTiersTwap(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(frost).setTaxTiersTwap(_index, _value);
    }

    function setTaxTiersRate(uint8 _index, uint256 _value) public onlyOperator returns (bool) {
        return ITaxable(frost).setTaxTiersRate(_index, _value);
    }

    function enableAutoCalculateTax() public onlyOperator {
        ITaxable(frost).enableAutoCalculateTax();
    }

    function disableAutoCalculateTax() public onlyOperator {
        ITaxable(frost).disableAutoCalculateTax();
    }

    function setTaxRate(uint256 _taxRate) public onlyOperator {
        ITaxable(frost).setTaxRate(_taxRate);
    }

    function setBurnThreshold(uint256 _burnThreshold) public onlyOperator {
        ITaxable(frost).setBurnThreshold(_burnThreshold);
    }

    function setTaxCollectorAddress(address _taxCollectorAddress) public onlyOperator {
        ITaxable(frost).setTaxCollectorAddress(_taxCollectorAddress);
    }

    function excludeAddressFromTax(address _address) external onlyOperator returns (bool) {
        return _excludeAddressFromTax(_address);
    }

    function _excludeAddressFromTax(address _address) private returns (bool) {
        if (!ITaxable(frost).isAddressExcluded(_address)) {
            return ITaxable(frost).excludeAddress(_address);
        }
    }

    function includeAddressInTax(address _address) external onlyOperator returns (bool) {
        return _includeAddressInTax(_address);
    }

    function _includeAddressInTax(address _address) private returns (bool) {
        if (ITaxable(frost).isAddressExcluded(_address)) {
            return ITaxable(frost).includeAddress(_address);
        }
    }

    function taxRate() external returns (uint256) {
        return ITaxable(frost).taxRate();
    }

    function addLiquidityTaxFree(
        address token,
        uint256 amtFrost,
        uint256 amtToken,
        uint256 amtFrostMin,
        uint256 amtTokenMin
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtFrost != 0 && amtToken != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(frost).transferFrom(msg.sender, address(this), amtFrost);
        IERC20(token).transferFrom(msg.sender, address(this), amtToken);
        _approveTokenIfNeeded(frost, uniRouter);
        _approveTokenIfNeeded(token, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtFrost;
        uint256 resultAmtToken;
        uint256 liquidity;
        (resultAmtFrost, resultAmtToken, liquidity) = IUniswapV2Router(uniRouter).addLiquidity(
            frost,
            token,
            amtFrost,
            amtToken,
            amtFrostMin,
            amtTokenMin,
            msg.sender,
            block.timestamp
        );

        if(amtFrost.sub(resultAmtFrost) > 0) {
            IERC20(frost).transfer(msg.sender, amtFrost.sub(resultAmtFrost));
        }
        if(amtToken.sub(resultAmtToken) > 0) {
            IERC20(token).transfer(msg.sender, amtToken.sub(resultAmtToken));
        }
        return (resultAmtFrost, resultAmtToken, liquidity);
    }

    function addLiquidityAVAXTaxFree(
        uint256 amtFrost,
        uint256 amtFrostMin,
        uint256 amtAvaxMin
    )
        external
        payable
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        require(amtFrost != 0 && msg.value != 0, "amounts can't be 0");
        _excludeAddressFromTax(msg.sender);

        IERC20(frost).transferFrom(msg.sender, address(this), amtFrost);
        _approveTokenIfNeeded(frost, uniRouter);

        _includeAddressInTax(msg.sender);

        uint256 resultAmtFrost;
        uint256 resultAmtAvax;
        uint256 liquidity;
        (resultAmtFrost, resultAmtAvax, liquidity) = IUniswapV2Router(uniRouter).addLiquidityAVAX{value: msg.value}(
            frost,
            amtFrost,
            amtFrostMin,
            amtAvaxMin,
            msg.sender,
            block.timestamp
        );

        if(amtFrost.sub(resultAmtFrost) > 0) {
            IERC20(frost).transfer(msg.sender, amtFrost.sub(resultAmtFrost));
        }
        return (resultAmtFrost, resultAmtAvax, liquidity);
    }

    function setTaxableFrostOracle(address _frostOracle) external onlyOperator {
        ITaxable(frost).setFrostOracle(_frostOracle);
    }

    function transferTaxOffice(address _newTaxOffice) external onlyOperator {
        ITaxable(frost).setTaxOffice(_newTaxOffice);
    }

    function taxFreeTransferFrom(
        address _sender,
        address _recipient,
        uint256 _amt
    ) external {
        require(taxExclusionEnabled[msg.sender], "Address not approved for tax free transfers");
        _excludeAddressFromTax(_sender);
        IERC20(frost).transferFrom(_sender, _recipient, _amt);
        _includeAddressInTax(_sender);
    }

    function setTaxExclusionForAddress(address _address, bool _excluded) external onlyOperator {
        taxExclusionEnabled[_address] = _excluded;
    }

    function _approveTokenIfNeeded(address _token, address _router) private {
        if (IERC20(_token).allowance(address(this), _router) == 0) {
            IERC20(_token).approve(_router, type(uint256).max);
        }
    }
}
