// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

/* ========================= ERC20 MOCK ========================= */
contract ERC20Mock {
    string public name;
    string public symbol;
    uint8  public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory _n, string memory _s, uint8 _d) {
        name = _n; symbol = _s; decimals = _d;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply   += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "bal");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        require(balanceOf[from] >= amt, "bal");
        uint256 al = allowance[from][msg.sender];
        require(al >= amt, "allow");
        if (al != type(uint256).max) allowance[from][msg.sender] = al - amt;
        balanceOf[from] -= amt;
        balanceOf[to]   += amt;
        return true;
    }
}

/* ===================== CHAINLINK FEED MOCK ==================== */
contract AggregatorV3Mock {
    int256 private _answer;
    uint8  private _decimals;

    constructor(uint8 d, int256 a) {
        _decimals = d;
        _answer   = a;
    }

    function setAnswer(int256 a) external { _answer = a; }
    function setDecimals(uint8 d) external { _decimals = d; }

    function decimals() external view returns (uint8) { return _decimals; }

    // Firma compatible con Chainlink
    function latestRoundData()
        external
        view
        returns (uint80, int256 answer, uint256, uint256, uint80)
    {
        return (0, _answer, 0, block.timestamp, 0);
    }
}

/* ============== UNISWAP V2 ROUTER MIN-INTERFACE =============== */
interface IUniswapV2Router02_Min {
    function WETH() external pure returns (address);
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
    function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts);
    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address to, uint deadline)
        external payable returns (uint[] memory amounts);
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external returns (uint[] memory amounts);
    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline)
        external returns (uint[] memory amounts);
}

/* ======================= UNISWAP ROUTER MOCK ================== */
contract RouterV2Mock is IUniswapV2Router02_Min {
    address public immutable _weth;

    // Valores “programables” para testear slippage y cotizaciones
    uint256 public nextOut;  // último elemento deseado en getAmountsOut / swaps
    uint256 public nextIn;   // primer elemento deseado en getAmountsIn

    constructor(address weth_) { _weth = weth_; }

    function WETH() external pure override returns (address) {
        // Para tests: cualquier non-zero address sirve
        return address(0xBEEF);
    }

    function setNextOut(uint256 v) external { nextOut = v; }
    function setNextIn(uint256 v)  external { nextIn  = v; }

    function getAmountsOut(uint amountIn, address[] calldata path)
        external view override returns (uint[] memory amounts)
    {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        amounts[amounts.length-1] = (nextOut == 0 ? amountIn : nextOut);
    }

    function getAmountsIn(uint amountOut, address[] calldata path)
        external view override returns (uint[] memory amounts)
    {
        amounts = new uint[](path.length);
        amounts[0] = (nextIn == 0 ? amountOut : nextIn);
        amounts[amounts.length-1] = amountOut;
    }

    function swapExactETHForTokens(uint amountOutMin, address[] calldata path, address, uint)
        external payable override returns (uint[] memory amounts)
    {
        amounts = new uint[](path.length);
        amounts[0] = msg.value;
        uint256 out = (nextOut == 0 ? msg.value : nextOut);
        require(out >= amountOutMin, "slip");
        amounts[amounts.length-1] = out;
    }

    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address, uint)
        external view override returns (uint[] memory amounts) {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        uint256 out = (nextOut == 0 ? amountIn : nextOut);
        require(out >= amountOutMin, "slip");
        amounts[amounts.length-1] = out;
    }

    function swapExactTokensForETH(uint amountIn, uint amountOutMin, address[] calldata path, address, uint)
        external view override returns (uint[] memory amounts)
    {
        amounts = new uint[](path.length);
        amounts[0] = amountIn;
        uint256 out = (nextOut == 0 ? amountIn : nextOut);
        require(out >= amountOutMin, "slip");
        amounts[amounts.length-1] = out;
    }
}
