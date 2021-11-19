// SPDX-License-Identifier: GPL-3.0-or-later
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

import "@balancer-labs/v2-solidity-utils/contracts/helpers/BalancerErrors.sol";
import "@balancer-labs/v2-solidity-utils/contracts/helpers/ERC20Helpers.sol";
import "@balancer-labs/v2-solidity-utils/contracts/math/FixedPoint.sol";

import "@balancer-labs/v2-pool-utils/contracts/BasePool.sol";
import "@balancer-labs/v2-pool-utils/contracts/interfaces/IRateProvider.sol";
import "@balancer-labs/v2-pool-utils/contracts/rates/PriceRateCache.sol";

import "@balancer-labs/v2-vault/contracts/interfaces/IGeneralPool.sol";

import "./LinearMath.sol";
import "./LinearPoolUserData.sol";

/**
 * @dev Linear Pools are designed to hold two assets: "main" and "wrapped" tokens that have an equal value underlying
 * token (e.g., DAI and aDAI). The Pool will register three tokens in the Vault however: the two assets and the BPT
 * itself, so that BPT can be exchanged (effectively joining and exiting) via swaps.
 *
 * Unlike most other Pools, this one does not attempt to create revenue by charging fees: value is derived by holding
 * the wrapped, yield-bearing asset.
 *
 * There must be an external feed available to provide an exact, non-manipulable exchange rate between the tokens.
 */
contract LinearPool is BasePool, IGeneralPool, IRateProvider {
    using WordCodec for bytes32;
    using FixedPoint for uint256;
    using PriceRateCache for bytes32;
    using LinearPoolUserData for bytes;

    uint256 private constant _TOTAL_TOKENS = 3; // Main token, wrapped token, BPT

    // Linear Pools don't lock any BPT, since they fully support having zero main and wrapped token balances
    uint256 private constant _LINEAR_MINIMUM_BPT = 0;
    uint256 private constant _MAX_TOKEN_BALANCE = 2**(112) - 1;

    IERC20 private immutable _mainToken;
    IERC20 private immutable _wrappedToken;

    uint256 private immutable _bptIndex;
    uint256 private immutable _mainIndex;
    uint256 private immutable _wrappedIndex;

    uint256 private immutable _scalingFactorMainToken;
    uint256 private immutable _scalingFactorWrappedToken;

    // Store both targets in one slot
    // [   128 bits   |    128 bits   ]
    // [ upper target |  lower target ]
    // [MSB                        LSB]
    bytes32 private _packedTargets;

    uint256 private constant _LOWER_TARGET_OFFSET = 0;
    uint256 private constant _UPPER_TARGET_OFFSET = 128;

    bytes32 private _wrappedTokenRateCache;
    IRateProvider private immutable _wrappedTokenRateProvider;

    event TargetsSet(IERC20 indexed token, uint256 lowerTarget, uint256 upperTarget);
    event PriceRateProviderSet(IERC20 indexed token, IRateProvider indexed provider, uint256 cacheDuration);
    event PriceRateCacheUpdated(IERC20 indexed token, uint256 rate);
    enum ExitKind { EXACT_BPT_IN_FOR_TOKENS_OUT }

    // The constructor arguments are received in a struct to work around stack-too-deep issues
    struct NewPoolParams {
        IVault vault;
        string name;
        string symbol;
        IERC20 mainToken;
        IERC20 wrappedToken;
        uint256 lowerTarget;
        uint256 upperTarget;
        uint256 swapFeePercentage;
        uint256 pauseWindowDuration;
        uint256 bufferPeriodDuration;
        IRateProvider wrappedTokenRateProvider;
        uint256 wrappedTokenRateCacheDuration;
        address owner;
    }

    constructor(NewPoolParams memory params)
        BasePool(
            params.vault,
            IVault.PoolSpecialization.GENERAL,
            params.name,
            params.symbol,
            _sortTokens(params.mainToken, params.wrappedToken, IERC20(this)),
            new address[](_TOTAL_TOKENS),
            params.swapFeePercentage,
            params.pauseWindowDuration,
            params.bufferPeriodDuration,
            params.owner
        )
    {
        // Set tokens
        _mainToken = params.mainToken;
        _wrappedToken = params.wrappedToken;

        // Set token indexes
        (uint256 mainIndex, uint256 wrappedIndex, uint256 bptIndex) = _getSortedTokenIndexes(
            params.mainToken,
            params.wrappedToken,
            IERC20(this)
        );
        _bptIndex = bptIndex;
        _mainIndex = mainIndex;
        _wrappedIndex = wrappedIndex;

        // Set scaling factors
        _scalingFactorMainToken = _computeScalingFactor(params.mainToken);
        _scalingFactorWrappedToken = _computeScalingFactor(params.wrappedToken);

        // Set initial targets
        _setTargets(params.mainToken, params.lowerTarget, params.upperTarget);

        // Set wrapped token rate cache
        _wrappedTokenRateProvider = params.wrappedTokenRateProvider;
        emit PriceRateProviderSet(
            params.wrappedToken,
            params.wrappedTokenRateProvider,
            params.wrappedTokenRateCacheDuration
        );
        (bytes32 cache, uint256 rate) = _getNewWrappedTokenRateCache(
            params.wrappedTokenRateProvider,
            params.wrappedTokenRateCacheDuration
        );
        _wrappedTokenRateCache = cache;
        emit PriceRateCacheUpdated(params.wrappedToken, rate);
    }

    function getMainToken() external view returns (address) {
        return address(_mainToken);
    }

    function getWrappedToken() external view returns (address) {
        return address(_wrappedToken);
    }

    function getBptIndex() external view returns (uint256) {
        return _bptIndex;
    }

    function getMainIndex() external view returns (uint256) {
        return _mainIndex;
    }

    function getWrappedIndex() external view returns (uint256) {
        return _wrappedIndex;
    }

    /**
     * @dev Finishes initialization of the Linear Pool: it is unusable before calling this function.
     *
     * Since Linear Pools have preminted BPT stored in the Vault, they require an initial join to deposit that BPT.
     * Unfortunately, this cannot be performed during construction, as a join involves a callback function on the
     * Pool, and the Pool will not have any code until construction finishes. Therefore, this must happen in a
     * separate call.
     *
     * It is highly recommended to create Linear pools using the LinearPoolFactory, which calls `initialize`
     * automatically.
     */
    function initialize() external {
        bytes32 poolId = getPoolId();
        (IERC20[] memory tokens, , ) = getVault().getPoolTokens(poolId);

        // During initialization, the Pool will mint the entire BPT supply for itself, and then join with it.
        uint256[] memory maxAmountsIn = new uint256[](_TOTAL_TOKENS);
        maxAmountsIn[tokens[0] == IERC20(this) ? 0 : tokens[1] == IERC20(this) ? 1 : 2] = _MAX_TOKEN_BALANCE;

        IVault.JoinPoolRequest memory request = IVault.JoinPoolRequest({
            assets: _asIAsset(tokens),
            maxAmountsIn: maxAmountsIn,
            userData: "",
            fromInternalBalance: false
        });

        getVault().joinPool(poolId, address(this), address(this), request);
    }

    function onSwap(
        SwapRequest memory request,
        uint256[] memory balances,
        uint256 indexIn,
        uint256 indexOut
    ) public override onlyVault(request.poolId) whenNotPaused returns (uint256) {
        // Validate indices, which are passed in here because Linear Pools have the General specialization.
        // Note that they are only used within the onSwap function itself.
        //
        // Since we know that the order of `balances` must correspond to the token order in the Vault, and we
        // already stored the indices of all three tokens during construction, there is no need to pass these
        // indices through to internal functions called from onSwap.
        _require(indexIn < _TOTAL_TOKENS && indexOut < _TOTAL_TOKENS, Errors.OUT_OF_BOUNDS);

        _cacheWrappedTokenRateIfNecessary();
        uint256[] memory scalingFactors = _scalingFactors();
        (uint256 lowerTarget, uint256 upperTarget) = getTargets();
        LinearMath.Params memory params = LinearMath.Params({
            fee: getSwapFeePercentage(),
            rate: FixedPoint.ONE,
            lowerTarget: lowerTarget,
            upperTarget: upperTarget
        });

        if (request.kind == IVault.SwapKind.GIVEN_IN) {
            _upscaleArray(balances, scalingFactors);
            request.amount = _upscale(request.amount, scalingFactors[indexIn]);
            uint256 amountOut = _onSwapGivenIn(request, balances, params);
            // amountOut tokens are exiting the Pool, so we round down.
            return _downscaleDown(amountOut, scalingFactors[indexOut]);
        } else {
            _upscaleArray(balances, scalingFactors);
            request.amount = _upscale(request.amount, scalingFactors[indexOut]);
            uint256 amountIn = _onSwapGivenOut(request, balances, params);
            // amountIn tokens are entering the Pool, so we round up.
            return _downscaleUp(amountIn, scalingFactors[indexIn]);
        }
    }

    function _onSwapGivenIn(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        if (request.tokenIn == IERC20(this)) {
            return _swapGivenBptIn(request, balances, params);
        } else if (request.tokenIn == _mainToken) {
            return _swapGivenMainIn(request, balances, params);
        } else if (request.tokenIn == _wrappedToken) {
            return _swapGivenWrappedIn(request, balances, params);
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _swapGivenBptIn(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenOut == _mainToken || request.tokenOut == _wrappedToken, Errors.INVALID_TOKEN);
        return
            (request.tokenOut == _mainToken ? LinearMath._calcMainOutPerBptIn : LinearMath._calcWrappedOutPerBptIn)(
                request.amount,
                balances[_mainIndex],
                balances[_wrappedIndex],
                _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                params
            );
    }

    function _swapGivenMainIn(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenOut == _wrappedToken || request.tokenOut == IERC20(this), Errors.INVALID_TOKEN);
        return
            request.tokenOut == IERC20(this)
                ? LinearMath._calcBptOutPerMainIn(
                    request.amount,
                    balances[_mainIndex],
                    balances[_wrappedIndex],
                    _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                    params
                )
                : LinearMath._calcWrappedOutPerMainIn(request.amount, balances[_mainIndex], params);
    }

    function _swapGivenWrappedIn(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenOut == _mainToken || request.tokenOut == IERC20(this), Errors.INVALID_TOKEN);
        return
            request.tokenOut == IERC20(this)
                ? LinearMath._calcBptOutPerWrappedIn(
                    request.amount,
                    balances[_mainIndex],
                    balances[_wrappedIndex],
                    _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                    params
                )
                : LinearMath._calcMainOutPerWrappedIn(request.amount, balances[_mainIndex], params);
    }

    function _onSwapGivenOut(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        if (request.tokenOut == IERC20(this)) {
            return _swapGivenBptOut(request, balances, params);
        } else if (request.tokenOut == _mainToken) {
            return _swapGivenMainOut(request, balances, params);
        } else if (request.tokenOut == _wrappedToken) {
            return _swapGivenWrappedOut(request, balances, params);
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _swapGivenBptOut(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenIn == _mainToken || request.tokenIn == _wrappedToken, Errors.INVALID_TOKEN);
        return
            (request.tokenIn == _mainToken ? LinearMath._calcMainInPerBptOut : LinearMath._calcWrappedInPerBptOut)(
                request.amount,
                balances[_mainIndex],
                balances[_wrappedIndex],
                _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                params
            );
    }

    function _swapGivenMainOut(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenIn == _wrappedToken || request.tokenIn == IERC20(this), Errors.INVALID_TOKEN);
        return
            request.tokenIn == IERC20(this)
                ? LinearMath._calcBptInPerMainOut(
                    request.amount,
                    balances[_mainIndex],
                    balances[_wrappedIndex],
                    _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                    params
                )
                : LinearMath._calcWrappedInPerMainOut(request.amount, balances[_mainIndex], params);
    }

    function _swapGivenWrappedOut(
        SwapRequest memory request,
        uint256[] memory balances,
        LinearMath.Params memory params
    ) internal view returns (uint256) {
        _require(request.tokenIn == _mainToken || request.tokenIn == IERC20(this), Errors.INVALID_TOKEN);
        return
            request.tokenIn == IERC20(this)
                ? LinearMath._calcBptInPerWrappedOut(
                    request.amount,
                    balances[_mainIndex],
                    balances[_wrappedIndex],
                    _MAX_TOKEN_BALANCE - balances[_bptIndex], // _MAX_TOKEN_BALANCE is always greater than BPT balance
                    params
                )
                : LinearMath._calcMainInPerWrappedOut(request.amount, balances[_mainIndex], params);
    }

    function _onInitializePool(
        bytes32,
        address sender,
        address recipient,
        uint256[] memory,
        bytes memory
    ) internal view override whenNotPaused returns (uint256, uint256[] memory) {
        // Linear Pools can only be initialized by the Pool performing the initial join via the `initialize` function.
        _require(sender == address(this), Errors.INVALID_INITIALIZATION);
        _require(recipient == address(this), Errors.INVALID_INITIALIZATION);

        // The full BPT supply will be minted and deposited in the Pool. Note that there is no need to approve the Vault
        // as it already has infinite BPT allowance.
        uint256[] memory amountsIn = new uint256[](_TOTAL_TOKENS);
        amountsIn[_bptIndex] = _MAX_TOKEN_BALANCE;

        return (_MAX_TOKEN_BALANCE, amountsIn);
    }

    function _onJoinPool(
        bytes32,
        address,
        address,
        uint256[] memory,
        uint256,
        uint256,
        uint256[] memory,
        bytes memory
    )
        internal
        pure
        override
        returns (
            uint256,
            uint256[] memory,
            uint256[] memory
        )
    {
        _revert(Errors.UNHANDLED_BY_LINEAR_POOL);
    }

    /**
     * @dev Proportional exit is only enabled when pool is paused.
     */
    function _onExitPool(
        bytes32,
        address,
        address,
        uint256[] memory balances,
        uint256,
        uint256,
        uint256[] memory,
        bytes memory userData
    )
        internal
        view
        override
        returns (
            uint256 bptAmountIn,
            uint256[] memory amountsOut,
            uint256[] memory dueProtocolFeeAmounts
        )
    {
        LinearPoolUserData.ExitKind kind = userData.exitKind();

        // Exits typically revert, except for the proportional exit when the emergency pause mechanism has been
        // triggered. This allows for a simple and safe way to exit the Pool.
        if (kind == LinearPoolUserData.ExitKind.EXACT_BPT_IN_FOR_TOKENS_OUT) {
            _ensurePaused();
            // Note that this will cause the user's BPT to be burned, which is not something that happens during
            // regular operation of this Pool, and may lead to accounting errors. Because of this, it is highly
            // advisable to stop using a Pool after it is paused and the pause window expires.

            (bptAmountIn, amountsOut) = _proportionalExit(balances, userData);
            // For simplicity, due protocol fees are set to zero.
            dueProtocolFeeAmounts = new uint256[](_getTotalTokens());
        } else {
            _revert(Errors.UNHANDLED_BY_LINEAR_POOL);
        }
    }

    function _proportionalExit(uint256[] memory balances, bytes memory userData)
        private
        view
        returns (uint256, uint256[] memory)
    {
        // This proportional exit function is only enabled if the contract is paused, to provide users a way to
        // retrieve their tokens in case of an emergency.
        //
        // This particular exit function is the only one available because it is the simplest, and therefore least
        // likely to revert and lock funds.

        uint256 bptAmountIn = userData.exactBptInForTokensOut();
        // Note that there is no minimum amountOut parameter: this is handled by `IVault.exitPool`.

        // This process burns BPT, rendering the "_MAX_TOKEN_BALANCE - balances[_bptIndex]" approximation of the
        // virtual BPT inaccurate. So we need to calculate it exactly here.
        uint256[] memory amountsOut = LinearMath._calcTokensOutGivenExactBptIn(
            balances,
            bptAmountIn,
            _getVirtualSupply(balances[_bptIndex]),
            _bptIndex
        );

        return (bptAmountIn, amountsOut);
    }

    function _getMaxTokens() internal pure override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    function _getMinimumBpt() internal pure override returns (uint256) {
        return _LINEAR_MINIMUM_BPT;
    }

    function _getTotalTokens() internal view virtual override returns (uint256) {
        return _TOTAL_TOKENS;
    }

    function _scalingFactor(IERC20 token) internal view virtual override returns (uint256) {
        if (token == _mainToken) {
            return _scalingFactorMainToken;
        } else if (token == _wrappedToken) {
            return _scalingFactorWrappedToken.mulDown(_getWrappedTokenCachedRate());
        } else if (token == IERC20(this)) {
            return FixedPoint.ONE;
        } else {
            _revert(Errors.INVALID_TOKEN);
        }
    }

    function _scalingFactors() internal view virtual override returns (uint256[] memory) {
        uint256[] memory scalingFactors = new uint256[](_TOTAL_TOKENS);
        scalingFactors[_mainIndex] = _scalingFactorMainToken;
        scalingFactors[_wrappedIndex] = _scalingFactorWrappedToken.mulDown(_getWrappedTokenCachedRate());
        scalingFactors[_bptIndex] = FixedPoint.ONE;
        return scalingFactors;
    }

    // Price rates

    function getRate() public view override returns (uint256) {
        bytes32 poolId = getPoolId();
        (, uint256[] memory balances, ) = getVault().getPoolTokens(poolId);
        _upscaleArray(balances, _scalingFactors());
        uint256 totalBalance = balances[_mainIndex] + balances[_wrappedIndex];
        return totalBalance.divUp(_MAX_TOKEN_BALANCE - balances[_bptIndex]);
    }

    function getWrappedTokenRateProvider() public view returns (IRateProvider) {
        return _wrappedTokenRateProvider;
    }

    function getWrappedTokenRateCache()
        external
        view
        returns (
            uint256 rate,
            uint256 duration,
            uint256 expires
        )
    {
        rate = _wrappedTokenRateCache.getValue();
        (duration, expires) = _wrappedTokenRateCache.getTimestamps();
    }

    function setWrappedTokenRateCacheDuration(uint256 duration) external authenticate {
        _updateWrappedTokenRateCache(duration);
        emit PriceRateProviderSet(_wrappedToken, getWrappedTokenRateProvider(), duration);
    }

    function updateWrappedTokenRateCache() external {
        _updateWrappedTokenRateCache(_wrappedTokenRateCache.getDuration());
    }

    function _cacheWrappedTokenRateIfNecessary() internal {
        (uint256 duration, uint256 expires) = _wrappedTokenRateCache.getTimestamps();
        // solhint-disable-next-line not-rely-on-time
        if (block.timestamp > expires) {
            _updateWrappedTokenRateCache(duration);
        }
    }

    function _updateWrappedTokenRateCache(uint256 duration) private {
        (bytes32 cache, uint256 rate) = _getNewWrappedTokenRateCache(_wrappedTokenRateProvider, duration);
        _wrappedTokenRateCache = cache;
        emit PriceRateCacheUpdated(_wrappedToken, rate);
    }

    function _getNewWrappedTokenRateCache(IRateProvider provider, uint256 duration)
        private
        view
        returns (bytes32 cache, uint256 rate)
    {
        rate = provider.getRate();
        cache = PriceRateCache.encode(rate, duration);
    }

    function _getWrappedTokenCachedRate() internal view virtual returns (uint256) {
        return _wrappedTokenRateCache.getValue();
    }

    function getTargets() public view returns (uint256 lowerTarget, uint256 upperTarget) {
        lowerTarget = _packedTargets.decodeUint128(_LOWER_TARGET_OFFSET);
        upperTarget = _packedTargets.decodeUint128(_UPPER_TARGET_OFFSET);
    }

    function _setTargets(
        IERC20 mainToken,
        uint256 lowerTarget,
        uint256 upperTarget
    ) private {
        _require(lowerTarget <= upperTarget, Errors.LOWER_GREATER_THAN_UPPER_TARGET);
        _require(upperTarget <= _MAX_TOKEN_BALANCE, Errors.UPPER_TARGET_TOO_HIGH);

        // Pack targets as two uint128 values into a single storage. This results in targets being capped to 128 bits,
        // but that's fine because they are guaranteed to be lower than the 112-bit _MAX_TOKEN_BALANCE.
        _packedTargets =
            WordCodec.encodeUint(lowerTarget, _LOWER_TARGET_OFFSET) |
            WordCodec.encodeUint(upperTarget, _UPPER_TARGET_OFFSET);
        emit TargetsSet(mainToken, lowerTarget, upperTarget);
    }

    function setTargets(uint256 newLowerTarget, uint256 newUpperTarget) external authenticate {
        bytes32 poolId = getPoolId();
        (, uint256[] memory balances, ) = getVault().getPoolTokens(poolId);
        _upscaleArray(balances, _scalingFactors());

        // For a new target range to be valid:
        //  - the pool must currently be between the current targets (meaning no fees are currently pending)
        //  - the pool must currently be between the new targets (meaning setting them does not cause for fees to be
        //    pending)
        //
        // The first requirement could be relaxed, as the LPs actually benefit from the pending fees not being paid out,
        // but being stricter makes analysis easier at little expense.

        (uint256 currentLowerTarget, uint256 currentUpperTarget) = getTargets();
        _require(
            balances[_mainIndex] >= currentLowerTarget && balances[_mainIndex] <= currentUpperTarget,
            Errors.OUT_OF_TARGET_RANGE
        );

        _require(
            balances[_mainIndex] >= newLowerTarget && balances[_mainIndex] <= newUpperTarget,
            Errors.OUT_OF_NEW_TARGET_RANGE
        );

        _setTargets(_mainToken, newLowerTarget, newUpperTarget);
    }

    function _isOwnerOnlyAction(bytes32 actionId) internal view virtual override returns (bool) {
        return
            (actionId == getActionId(this.setTargets.selector)) ||
            (actionId == getActionId(this.setWrappedTokenRateCacheDuration.selector)) ||
            super._isOwnerOnlyAction(actionId);
    }

    /**
     * @dev Returns the number of tokens in circulation.
     *
     * In other pools, this would be the same as `totalSupply`, but since this pool pre-mints all BPT, `totalSupply`
     * remains constant, whereas `virtualSupply` increases as users join the pool and decreases as they exit it.
     */
    function getVirtualSupply() external view returns (uint256) {
        (, uint256[] memory balances, ) = getVault().getPoolTokens(getPoolId());
        // Note that unlike all other balances, the Vault's BPT balance does not need scaling. BPT are always 18-bits,
        // so the scaling factor is FixedPoint.ONE.

        return _getVirtualSupply(balances[_bptIndex]);
    }

    function _getVirtualSupply(uint256 bptBalance) internal view returns (uint256) {
        return totalSupply().sub(bptBalance);
    }
}
