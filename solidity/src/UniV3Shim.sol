// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
}

interface ISwapRouterV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }
    function exactInput(ExactInputParams calldata params) external payable returns (uint256);

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256);

    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
    }
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256);
}

library PathLib {
    function tokenInExactInput(bytes calldata path) internal pure returns (address a) {
        require(path.length >= 20, "path too short");
        assembly {
            a := shr(96, calldataload(path.offset))
        }
    }

    function tokenInExactOutput(bytes calldata path) internal pure returns (address a) {
        require(path.length >= 20, "path too short");
        assembly {
            // last 20 bytes of the (reversed) path = tokenIn
            a := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
    }
}

contract UniV3Shim {
    using PathLib for bytes;

    event PreSwap(address indexed caller, address indexed tokenIn, uint256 callerBalance, uint256 allowanceToShim, uint256 amountInOrMax, uint256 minOrOut);
    event PostSwap(uint256 amountOutOrIn);
    event Refunded(address indexed token, uint256 amount);

    ISwapRouterV3 public immutable router;
    constructor(address _router) { router = ISwapRouterV3(_router); }

    // ========= exactInput (multi-hop path) =========
    function exactInputShim(
        bytes calldata path,
        address recipient,
        uint256 amountIn,
        uint256 minOut
    ) external payable returns (uint256 amountOut) {
        address tokenIn = path.tokenInExactInput();

        uint256 bal = IERC20(tokenIn).balanceOf(msg.sender);
        uint256 alw = IERC20(tokenIn).allowance(msg.sender, address(this));
        emit PreSwap(msg.sender, tokenIn, bal, alw, amountIn, minOut);
        require(bal >= amountIn, "balance < amountIn");
        require(alw >= amountIn, "allowance < amountIn");

        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(tokenIn).approve(address(router), amountIn), "approve failed");

        ISwapRouterV3.ExactInputParams memory p = ISwapRouterV3.ExactInputParams({
            path: path,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minOut
        });

        try router.exactInput{value: msg.value}(p) returns (uint256 out) {
            amountOut = out;
            emit PostSwap(out);
        } catch (bytes memory reason) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }

        // Optional: clear approval
        IERC20(tokenIn).approve(address(router), 0);
    }

    // ========= exactOutput (multi-hop path) =========
    function exactOutputShim(
        bytes calldata path,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum
    ) external payable returns (uint256 amountIn) {
        address tokenIn = path.tokenInExactOutput();

        uint256 bal = IERC20(tokenIn).balanceOf(msg.sender);
        uint256 alw = IERC20(tokenIn).allowance(msg.sender, address(this));
        emit PreSwap(msg.sender, tokenIn, bal, alw, amountInMaximum, amountOut);
        require(bal >= amountInMaximum, "balance < maxIn");
        require(alw >= amountInMaximum, "allowance < maxIn");

        // Pull the maximum, approve router
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountInMaximum), "pull failed");
        require(IERC20(tokenIn).approve(address(router), amountInMaximum), "approve failed");

        ISwapRouterV3.ExactOutputParams memory p = ISwapRouterV3.ExactOutputParams({
            path: path,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum
        });

        try router.exactOutput{value: msg.value}(p) returns (uint256 inUsed) {
            amountIn = inUsed;
            emit PostSwap(inUsed);
        } catch (bytes memory reason) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }

        // Refund any unused input
        if (amountIn < amountInMaximum) {
            uint256 refund = amountInMaximum - amountIn;
            // reduce approval to zero for safety, then send refund
            IERC20(tokenIn).approve(address(router), 0);
            require(IERC20(tokenIn).transfer(msg.sender, refund), "refund failed");
            emit Refunded(tokenIn, refund);
        } else {
            // still clear approval
            IERC20(tokenIn).approve(address(router), 0);
        }
    }

    // ========= exactInputSingle =========
    function exactInputSingleShim(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountIn,
        uint256 minOut,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256 amountOut) {
        uint256 bal = IERC20(tokenIn).balanceOf(msg.sender);
        uint256 alw = IERC20(tokenIn).allowance(msg.sender, address(this));
        emit PreSwap(msg.sender, tokenIn, bal, alw, amountIn, minOut);
        require(bal >= amountIn, "balance < amountIn");
        require(alw >= amountIn, "allowance < amountIn");

        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull failed");
        require(IERC20(tokenIn).approve(address(router), amountIn), "approve failed");

        ISwapRouterV3.ExactInputSingleParams memory p = ISwapRouterV3.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        try router.exactInputSingle{value: msg.value}(p) returns (uint256 out) {
            amountOut = out;
            emit PostSwap(out);
        } catch (bytes memory reason) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }

        IERC20(tokenIn).approve(address(router), 0);
    }

    // ========= exactOutputSingle =========
    function exactOutputSingleShim(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        address recipient,
        uint256 amountOut,
        uint256 amountInMaximum,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256 amountIn) {
        uint256 bal = IERC20(tokenIn).balanceOf(msg.sender);
        uint256 alw = IERC20(tokenIn).allowance(msg.sender, address(this));
        emit PreSwap(msg.sender, tokenIn, bal, alw, amountInMaximum, amountOut);
        require(bal >= amountInMaximum, "balance < maxIn");
        require(alw >= amountInMaximum, "allowance < maxIn");

        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountInMaximum), "pull failed");
        require(IERC20(tokenIn).approve(address(router), amountInMaximum), "approve failed");

        ISwapRouterV3.ExactOutputSingleParams memory p = ISwapRouterV3.ExactOutputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: amountInMaximum,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        try router.exactOutputSingle{value: msg.value}(p) returns (uint256 inUsed) {
            amountIn = inUsed;
            emit PostSwap(inUsed);
        } catch (bytes memory reason) {
            assembly { revert(add(reason, 32), mload(reason)) }
        }

        // Refund unused input and clear approval
        if (amountIn < amountInMaximum) {
            uint256 refund = amountInMaximum - amountIn;
            IERC20(tokenIn).approve(address(router), 0);
            require(IERC20(tokenIn).transfer(msg.sender, refund), "refund failed");
            emit Refunded(tokenIn, refund);
        } else {
            IERC20(tokenIn).approve(address(router), 0);
        }
    }
}
