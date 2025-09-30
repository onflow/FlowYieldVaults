// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

// Optional: if your mock tokens support minting.
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

// ---------- Helper that handles V3 callbacks ----------
contract LPHelper {
    using SafeERC20 for IERC20;

    IPool   public immutable pool;
    IERC20  public immutable t0;
    IERC20  public immutable t1;
    address public immutable owner;

    constructor(address _pool) {
        pool  = IPool(_pool);
        t0    = IERC20(pool.token0());
        t1    = IERC20(pool.token1());
        owner = msg.sender; // broadcaster EOA
    }

    // V3-style callbacks
    function uniswapV3MintCallback(uint256 a0, uint256 a1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (a0 > 0) t0.safeTransfer(msg.sender, a0);
        if (a1 > 0) t1.safeTransfer(msg.sender, a1);
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        require(msg.sender == address(pool), "only pool");
        if (d0 > 0) t0.safeTransfer(msg.sender, uint256(d0));
        if (d1 > 0) t1.safeTransfer(msg.sender, uint256(d1));
    }

    // generic fallback to satisfy pools that use a generic callback entrypoint
    fallback() external {
        require(msg.sender == address(pool), "only pool");
        require(msg.data.length >= 4 + 96, "bad cb");
        (int256 a0, int256 a1, ) = abi.decode(msg.data[4:], (int256,int256,bytes));
        if (a0 > 0) t0.safeTransfer(msg.sender, uint256(a0));
        if (a1 > 0) t1.safeTransfer(msg.sender, uint256(a1));
    }

    // Owner ops
    function addLiquidity(int24 lower, int24 upper, uint128 L)
        external returns (uint256 used0, uint256 used1)
    {
        require(msg.sender == owner, "not owner");
        (used0, used1) = pool.mint(address(this), lower, upper, L, "");
    }

    function swapExact(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external returns (int256 d0, int256 d1)
    {
        require(msg.sender == owner, "not owner");
        (d0, d1) = pool.swap(address(this), zeroForOne, amountSpecified, sqrtPriceLimitX96, "");
    }

    // Pull tokens from the owner (EOA) after it approves this helper
    function pull(IERC20 tok, uint256 amt) external {
        require(msg.sender == owner, "not owner");
        tok.safeTransferFrom(msg.sender, address(this), amt);
    }
}

// ---------- Script that uses your minted tokens ----------
contract UseMintedUSDCWBTC is Script {
    using SafeERC20 for IERC20;

    // sqrt(1:1) and limits like Uniswap V3
    uint160 constant SQRT_PRICE_X96_1_1 = 79228162514264337593543950336;
    uint160 constant MIN_SQRT_RATIO = 4295128739 + 1;
    uint160 constant MAX_SQRT_RATIO =
        1461446703485210103287273052203988822378723970342 - 1;
    error Underfunded(address token, address holder, uint256 need, uint256 have);

function _tryMint(address token, address to, uint256 amount) internal {
    if (amount == 0) return;
    // best-effort: if token has no mint or caller lacks perms, we just log
    try IMintableERC20(token).mint(to, amount) { 
        console2.log("Minted", amount);
	console2.log("to", to);
	console2.log("for token", token);
    } catch {
        console2.log("mint() failed (no mint or not authorized) for token", token);
    }
}

function _ensureFunded(
    address token,
    address holder,
    uint256 need,
    uint256 mintIfPossible,
    bool tryMint
) internal {
    uint256 have = IERC20(token).balanceOf(holder);
    if (have >= need) return;

    if (tryMint && mintIfPossible > 0) {
        _tryMint(token, holder, mintIfPossible);
        have = IERC20(token).balanceOf(holder);
        if (have >= need) return;
    }

    console2.log("Insufficient funds");
    console2.log("token :", token);
    console2.log("holder:", holder);
    console2.log("need  :", need);
    console2.log("have  :", have);
    revert Underfunded(token, holder, need, have);
}


    function run() external {
        uint256 pk   = vm.envUint("PK_ACCOUNT");
        address eoa  = vm.addr(pk);

        address FACTORY = vm.envAddress("V3_FACTORY");
        uint24  FEE     = uint24(vm.envOr("V3_FEE", uint256(3000)));

        // Predeployed token addresses from your CREATE2 step
        address USDC = vm.envAddress("USDC_ADDR");
        address WBTC = vm.envAddress("WBTC_ADDR");

        // Sort for pool canonical order (token0 < token1)
        (address t0, address t1) = USDC < WBTC ? (USDC, WBTC) : (WBTC, USDC);

        // Funding amounts (base units). Defaults assume USDC 6d, WBTC 8d.
        // Feel free to override via env to something small first.
        uint256 usdcFund = vm.envOr("USDC_FUND", uint256(600_000 * 1e6)); // 600k USDC
        uint256 wbtcFund = vm.envOr("WBTC_FUND", uint256(600_000 * 1e8)); // 600k WBTC (test scale)
        uint256 amt0 = (t0 == USDC) ? usdcFund : wbtcFund;
        uint256 amt1 = (t1 == WBTC) ? wbtcFund : usdcFund;

        // LP & swap params (env-overridable)
        int24  lower     = int24(int256(vm.envOr("LOWER", int256(-600))));
        int24  upper     = int24(int256(vm.envOr("UPPER", int256( 600))));
        uint128 L        = uint128(vm.envOr("LIQ", uint256(109)));

        bool   zeroForOne = vm.envOr("ZERO_FOR_ONE", false);
        // Amount in is denominated in token0's base units
        uint256 defaultIn = (t0 == USDC) ? (10 * 1e6) : (10 * 1e8);
        int256 amountIn   = int256(vm.envOr("AMOUNT_IN_T0", defaultIn));
        uint160 limit     = zeroForOne ? (MIN_SQRT_RATIO) : (MAX_SQRT_RATIO);

        // Optional toggles
        bool SKIP_SWAP = vm.envOr("SKIP_SWAP", false);

        vm.startBroadcast(pk);

        // 1) Get/create pool
        address p;
        try IAMMFactory(FACTORY).getPool(t0, t1, FEE) returns (address existing) { p = existing; } catch {}
        if (p == address(0)) {
            p = IAMMFactory(FACTORY).createPool(t0, t1, FEE);
        }
        IPool pool = IPool(p);

        // 2) Initialize once (ignore if already initialized)
        try pool.initialize(SQRT_PRICE_X96_1_1) { } catch { }

        // 3) Deploy helper FROM EOA so owner == EOA
        LPHelper helper = new LPHelper(address(pool));

        // 4) Ensure EOA has enough balance to cover the planned pulls.
        //    If tokens support mint, this will mint; otherwise it will enforce funding.
bool TRY_MINT = vm.envOr("TRY_MINT", true);
uint256 usdcMint = vm.envOr("USDC_MINT", uint256(1_000_000 * 1e6));
uint256 wbtcMint = vm.envOr("WBTC_MINT", uint256(21 * 1e8));

_ensureFunded(t0, eoa, amt0, (t0 == USDC) ? usdcMint : wbtcMint, TRY_MINT);
_ensureFunded(t1, eoa, amt1, (t1 == WBTC) ? wbtcMint : usdcMint, TRY_MINT);

        // 5) Approve helper to pull your balances from the EOA
        // IERC20(t0).safeApprove(address(helper), 0);
        // IERC20(t0).safeApprove(address(helper), type(uint256).max);
        // IERC20(t1).safeApprove(address(helper), 0);
        // IERC20(t1).safeApprove(address(helper), type(uint256).max);
	IERC20(t0).forceApprove(address(helper), type(uint256).max);
	IERC20(t1).forceApprove(address(helper), type(uint256).max);

        // 6) Move funds into helper
        helper.pull(IERC20(t0), amt0);
        helper.pull(IERC20(t1), amt1);

        // 7) Add liquidity
        (uint256 used0, uint256 used1) = helper.addLiquidity(lower, upper, L);
        require(pool.liquidity() > 0, "pool liquidity zero");

        // 8) Swap against the position (optional)
        int256 d0;
        int256 d1;
        if (!SKIP_SWAP) {
            (d0, d1) = helper.swapExact(zeroForOne, amountIn, limit);
        }

        // Basic logs
        console2.log("Pool:   ", address(pool));
        console2.log("Helper: ", address(helper));
        console2.log("t0:"); console2.logAddress(t0);
        console2.log("t1:"); console2.logAddress(t1);

        console2.log("used0:"); console2.logUint(used0);
        console2.log("used1:"); console2.logUint(used1);

        if (!SKIP_SWAP) {
            console2.log("d0:"); console2.logInt(d0);
            console2.log("d1:"); console2.logInt(d1);
        } else {
            console2.log("swap skipped");
        }

        vm.stopBroadcast();
    }
}
