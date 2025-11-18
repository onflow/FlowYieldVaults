// copy to ./punch-swap-v3-contracts/src/periphery/

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.7.6;
pragma abicoder v2;

import '../core/interfaces/IPunchSwapV3Pool.sol';
import '@uniswap/lib/contracts/libraries/SafeERC20Namer.sol';

import './libraries/ChainId.sol';
import './interfaces/INonfungiblePositionManager.sol';
import './interfaces/INonfungibleTokenPositionDescriptor.sol';
import './interfaces/IERC20Metadata.sol';
import './libraries/PoolAddress.sol';
import './libraries/NFTDescriptor.sol';
import './libraries/TokenRatioSortOrder.sol';
import './NonfungibleTokenPositionDescriptorBase.sol';

/// @title Describes NFT token positions
/// @notice Produces a string containing the data URI for a JSON metadata string
contract EmulatorNonfungibleTokenPositionDescriptor is NonfungibleTokenPositionDescriptorBase {
    constructor(address WFLOW_ADDRESS, bytes32 _nativeCurrencyLabelBytes) NonfungibleTokenPositionDescriptorBase(WFLOW_ADDRESS, _nativeCurrencyLabelBytes) {}

    function _initializePriorities() override internal {
    }
}
