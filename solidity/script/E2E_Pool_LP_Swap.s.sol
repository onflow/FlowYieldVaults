// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

/* =========================
   Interfaces (V3-style)
   ========================= */
interface IAMMFactory {
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address);
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
    function feeAmountTickSpacing(uint24 fee) external view returns (int24); // optional
}

interface IPool {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
    function initialize(uint160 sqrtPriceX96) external;
    function liquidity() external view returns (uint128);

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
}

/* =========================
   Minimal ERC20 (test token)
   ========================= */
contract TestToken {
    string public name;
    string public symbol;
    uint8  public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 a) external { balanceOf[to] += a; }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        unchecked { balanceOf[msg.sender] -= a; balanceOf[to] += a; }
        return true;
    }

    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        require(al >= a, "allow");
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        require(balanceOf[f] >= a, "bal");
        unchecked { balanceOf[f] -= a; balanceOf[t] += a; }
        return true;
    }
}

/* =========================
   LP Helper with callbacks
   - Handles standard V3 callbacks
   - Also works with non-standard selectors via fallback()
   ========================= */
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

    // Standard Uniswap V3 callback names (many pools expect these)
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (amount0Owed > 0) t0.transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) t1.transfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (amount0Delta > 0) t0.transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) t1.transfer(msg.sender, uint256(amount1Delta));
    }

    // Universal handler for non-standard selectors:
    // decodes (int256 a0, int256 a1, bytes data) from calldata after the selector
    fallback() external {
        require(msg.sender == address(pool), "only pool");
        require(msg.data.length >= 4 + 96, "bad cb");
        (int256 a0, int256 a1, ) = abi.decode(msg.data[4:], (int256, int256, bytes));
        if (a0 > 0) t0.transfer(msg.sender, uint256(a0));
        if (a1 > 0) t1.transfer(msg.sender, uint256(a1));
    }

    receive() external payable {}

    // Owner ops
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

/* =========================
   Foundry Script:
   - Deploys 2 tokens
   - Creates/initializes pool
   - Deploys helper & funds it
   - Adds liquidity
   - Swaps and verifies math
   ========================= */
contract E2E_Pool_LP_Swap is Script {
    // 1:1 price (2^96)
    uint160 constant SQRT_PRICE_X96_1_1 = 79228162514264337593543950336;
    // V3 ratio bounds
    uint160 constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342 - 1;

    IAMMFactory public factory;
    uint24      public FEE;

    uint256 private DEPLOYER_PK;
    address private DEPLOYER_ADDR;

    function setUp() public {
        // Factory from env
        require(vm.envExists("V3_FACTORY"), "Missing V3_FACTORY");
        address f = vm.envAddress("V3_FACTORY");
        require(f.code.length > 0, "No code at V3_FACTORY");
        factory = IAMMFactory(f);

        // Private key from env (hex 0x… or decimal)
        if (vm.envExists("PK_ACCOUNT")) {
            DEPLOYER_PK = vm.envUint("PK_ACCOUNT");
        } else {
            revert("Set PK_ACCOUNT in env");
        }
        DEPLOYER_ADDR = vm.addr(DEPLOYER_PK);

        // Fee tier (default 3000)
        FEE = uint24(vm.envOr("V3_FEE", uint256(3000)));
        // Optional: ensure fee tier is enabled
        try factory.feeAmountTickSpacing(FEE) returns (int24 spacing) {
            require(spacing != 0, "fee tier not enabled");
        } catch {}
    }

    function _deployAndMint() internal returns (TestToken A, TestToken B) {
        A = new TestToken("Token Zero","T0");
        B = new TestToken("Token One","T1");
        // Mint to deployer (not DefaultSender)
        A.mint(DEPLOYER_ADDR, 1_000_000e18);
        B.mint(DEPLOYER_ADDR, 1_000_000e18);
    }

    function _sort(TestToken A, TestToken B) internal pure returns (TestToken token0, TestToken token1) {
        (token0, token1) = address(A) < address(B) ? (A, B) : (B, A);
    }

    function _getOrCreatePool(address token0, address token1) internal returns (IPool pool) {
        address p;
        try factory.getPool(token0, token1, FEE) returns (address existing) { p = existing; } catch {}
        if (p == address(0)) p = factory.createPool(token0, token1, FEE);
        require(p.code.length > 0, "pool create/get failed");
        pool = IPool(p);
        pool.initialize(SQRT_PRICE_X96_1_1);
    }

function _fundHelper(
    LPHelper helper,
    TestToken token0,
    TestToken token1,
    uint256 a0,
    uint256 a1
) internal {
    // We are inside vm.startBroadcast(DEPLOYER_PK), so msg.sender == DEPLOYER_ADDR.
    // The deployer owns the minted balances, so approvals and pulls line up.
    token0.approve(address(helper), type(uint256).max);
    token1.approve(address(helper), type(uint256).max);
    helper.pull(token0, a0);
    helper.pull(token1, a1);
}

    function _addLiquidity(
        LPHelper helper,
        TestToken token0,
        TestToken token1,
        int24 lower,
        int24 upper,
        uint128 L
    ) internal returns (uint256 used0, uint256 used1) {
        uint256 b0 = token0.balanceOf(address(helper));
        uint256 b1 = token1.balanceOf(address(helper));
        (used0, used1) = helper.addLiquidity(lower, upper, L);
        require(used0 > 0 && used1 > 0, "no tokens used for LP");
        require(b0 - token0.balanceOf(address(helper)) == used0, "LP token0 debit mismatch");
        require(b1 - token1.balanceOf(address(helper)) == used1, "LP token1 debit mismatch");
        require(IPool(address(helper.pool())).liquidity() > 0, "pool liquidity zero");
    }

    function _swap(
        LPHelper helper,
        TestToken token0,
        TestToken token1,
        bool zeroForOne,
        int256 amountIn,
        uint160 limit
    ) internal returns (int256 d0, int256 d1) {
        uint256 b0 = token0.balanceOf(address(helper));
        uint256 b1 = token1.balanceOf(address(helper));

        (d0, d1) = helper.swapExact(zeroForOne, amountIn, limit);

        uint256 a0 = token0.balanceOf(address(helper));
        uint256 a1 = token1.balanceOf(address(helper));

        uint256 spent0 = b0 > a0 ? b0 - a0 : 0;
        uint256 recv0  = a0 > b0 ? a0 - b0 : 0;
        uint256 spent1 = b1 > a1 ? b1 - a1 : 0;
        uint256 recv1  = a1 > b1 ? a1 - b1 : 0;

        require((spent0 > 0) != (spent1 > 0), "no unique input token");
        require((recv0  > 0) != (recv1  > 0), "no unique output token");

        uint256 absD0 = d0 < 0 ? uint256(-d0) : uint256(d0);
        uint256 absD1 = d1 < 0 ? uint256(-d1) : uint256(d1);

        require(absD0 == (spent0 > 0 ? spent0 : recv0), "token0 abs(delta) mismatch");
        require(absD1 == (spent1 > 0 ? spent1 : recv1), "token1 abs(delta) mismatch");
        require(absD0 > 0 || absD1 > 0, "zero swap");
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        // zeroForOne => MIN+1; oneForZero => MAX-1
        return zeroForOne ? (MIN_SQRT_RATIO + 1) : (MAX_SQRT_RATIO - 1);
    }

    function run() external {
        vm.startBroadcast(DEPLOYER_PK);

        (TestToken A, TestToken B) = _deployAndMint();
        (TestToken token0, TestToken token1) = _sort(A, B);
        IPool pool = _getOrCreatePool(address(token0), address(token1));

        LPHelper helper = new LPHelper(address(pool));
        _fundHelper(helper, token0, token1, 600_000e18, 600_000e18);

        (uint256 used0, uint256 used1) = _addLiquidity(helper, token0, token1, -60000, 60000, 100_000e9);

        // On this AMM, token0->token1 was zeroForOne=false based on traces
        (int256 d0, int256 d1) = _swap(
            helper,
            token0,
            token1,
            /*zeroForOne=*/ false,
            int256(10_000e18),
            _limit(false)
        );

        // Log absolute deltas (sign conventions vary by AMM)
        uint256 absD0 = d0 < 0 ? uint256(-d0) : uint256(d0);
        uint256 absD1 = d1 < 0 ? uint256(-d1) : uint256(d1);

        console2.log("Pool", address(pool));
        console2.log("LP used0", used0);
        console2.log("LP used1", used1);
        console2.log("Swap abs0", absD0);
        console2.log("Swap abs1", absD1);

        vm.stopBroadcast();
    }
}
