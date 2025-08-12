// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

interface IAMMFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initialize(uint160 sqrtPriceX96) external;
    function liquidity() external view returns (uint128);
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external returns (uint256 amount0, uint256 amount1);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external returns (int256 amount0, int256 amount1);
}

contract TestToken {
    string public name; string public symbol; uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s) { name = n; symbol = s; }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        unchecked { balanceOf[msg.sender]-=a; balanceOf[to]+=a; } return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender]; require(al >= a, "allow");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        require(balanceOf[f] >= a, "bal");
        unchecked { balanceOf[f]-=a; balanceOf[t]+=a; } return true;
    }
}

contract LPHelper {
    IPool     public immutable pool;
    TestToken public immutable t0;
    TestToken public immutable t1;
    address   public immutable owner;

    constructor(address _pool) {
        pool  = IPool(_pool);
        t0    = TestToken(pool.token0());
        t1    = TestToken(pool.token1());
        owner = msg.sender;
    }

    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (a0 > 0) t0.transfer(msg.sender, a0);
        if (a1 > 0) t1.transfer(msg.sender, a1);
    }
    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (d0 > 0) t0.transfer(msg.sender, uint256(d0));
        if (d1 > 0) t1.transfer(msg.sender, uint256(d1));
    }
    fallback() external {
        require(msg.sender == address(pool), "only pool");
        require(msg.data.length >= 4 + 96, "bad cb");
        (int256 a0, int256 a1,) = abi.decode(msg.data[4:], (int256,int256,bytes));
        if (a0 > 0) t0.transfer(msg.sender, uint256(a0));
        if (a1 > 0) t1.transfer(msg.sender, uint256(a1));
    }

    function addLiquidity(int24 lower, int24 upper, uint128 L) external returns (uint256 used0, uint256 used1) {
        require(msg.sender == owner, "not owner");
        (used0, used1) = pool.mint(address(this), lower, upper, L, "");
    }
    function swapExact(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external returns (int256 d0, int256 d1)
    {
        require(msg.sender == owner, "not owner");
        (d0, d1) = pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }
    function pull(TestToken tok, uint256 amt) external {
        require(msg.sender == owner, "not owner");
        tok.transferFrom(msg.sender, address(this), amt);
    }
}

contract OneShotCoordinator {
    uint160 constant SQRT_PRICE_X96_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342 - 1;

    event Done(address token0, address token1, address pool, address helper,
               uint256 used0, uint256 used1, int256 d0, int256 d1);

    function runAll(
        address factory,
        uint24 fee,
        // liquidity & swap params
        int24 lower, int24 upper, uint128 L,
        bool zeroForOne, int256 amountIn
    ) external {
        // 1) Deploy tokens, mint to THIS contract (so approvals/pulls line up)
        TestToken A = new TestToken("Token Zero","T0");
        TestToken B = new TestToken("Token One","T1");
        A.mint(address(this), 1_000_000e18);
        B.mint(address(this), 1_000_000e18);

        // 2) Sort
        (TestToken token0, TestToken token1) =
            address(A) < address(B) ? (A, B) : (B, A);

        // 3) Get/Create + init pool
        address p;
        try IAMMFactory(factory).getPool(address(token0), address(token1), fee) returns (address existing) { p = existing; } catch {}
        if (p == address(0)) {
            p = IAMMFactory(factory).createPool(address(token0), address(token1), fee);
        }
        IPool pool = IPool(p);
        pool.initialize(SQRT_PRICE_X96_1_1);

        // 4) Deploy helper (owner = THIS contract)
        LPHelper helper = new LPHelper(address(pool));

        // 5) Fund helper (approve + pull)
        token0.approve(address(helper), type(uint256).max);
        token1.approve(address(helper), type(uint256).max);
        helper.pull(token0, 600_000e18);
        helper.pull(token1, 600_000e18);

        // 6) Add liquidity
        (uint256 used0, uint256 used1) = helper.addLiquidity(lower, upper, L);
        require(pool.liquidity() > 0, "pool liquidity zero");

        // 7) Swap
        uint160 limit = zeroForOne ? (MIN_SQRT_RATIO + 1) : (MAX_SQRT_RATIO - 1);
        (int256 d0, int256 d1) = helper.swapExact(zeroForOne, amountIn, limit);

        emit Done(address(token0), address(token1), address(pool), address(helper), used0, used1, d0, d1);

        // Optional: send ownership/results to caller
        // e.g., transfer some tokens to msg.sender if you wish:
        // token0.transfer(msg.sender, token0.balanceOf(address(this)));
        // token1.transfer(msg.sender, token1.balanceOf(address(this)));
    }
}

contract E2E_Pool_LP_Swap_OneTx is Script {
    uint256 private DEPLOYER_PK;
    function setUp() public {
        require(vm.envExists("PK_ACCOUNT"), "Set PK_ACCOUNT");
        DEPLOYER_PK = vm.envUint("PK_ACCOUNT");
    }

    function run() external {
        address FACTORY = vm.envAddress("V3_FACTORY");
        uint24  FEE     = uint24(vm.envOr("V3_FEE", uint256(3000)));

        vm.startBroadcast(DEPLOYER_PK);
        OneShotCoordinator c = new OneShotCoordinator();
        // One single state-changing tx:
        c.runAll(
            FACTORY,
            FEE,
            /*lower*/ -60000,
            /*upper*/  60000,
            /*L*/      100_000e9,
            /*zeroForOne*/ false,
            /*amountIn*/   int256(10_000e18)
        );
        vm.stopBroadcast();
    }
}
