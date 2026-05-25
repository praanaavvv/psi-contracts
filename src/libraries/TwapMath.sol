// SPDX-License-Identifier: BSL-1.1
pragma solidity 0.8.31;

import { Math } from '@openzeppelin/contracts/utils/math/Math.sol';
import { DataTypes } from '../types/DataTypes.sol';
import { IPsiTwapOracle } from '../interfaces/IPsiTwapOracle.sol';

/// @title TwapMath
/// @notice Twap index calculations and yield distribution logic
/// @dev Handles time-weighted average price tracking for yield split between YES/NO sides
library TwapMath {
    using Math for uint256;

    /// @notice Calculate NO index from YES index and time
    /// @dev twapAccumulatorNo = totalTime * PRICE_SCALE - twapAccumulatorYes
    /// @param twapAccumulatorYes Cumulative YES index
    /// @param timeDelta Total time elapsed since last yield allocation
    /// @return twapAccumulatorNo Calculated NO index
    function calculateTwapAccumulatorNo(uint256 twapAccumulatorYes, uint256 timeDelta) internal pure returns (uint256 twapAccumulatorNo) {
        // Total possible index if YES was always at 100%
        uint256 maxIndex = timeDelta * DataTypes.PRICE_SCALE;
        // NO index is the complement
        twapAccumulatorNo = maxIndex - twapAccumulatorYes;
    }

    /// @notice Split yield weighted by both Twap prices AND asset amounts on each side
    /// @dev Distributes yield proportionally to USD value: (assets * avgPrice) for each side
    /// @param totalYield Total yield to distribute
    /// @param twapAccumulatorYesDelta YES price-time index delta for the period
    /// @param timeDelta Total time since last yield allocation
    /// @param assetsYes Total assets on YES side
    /// @param assetsNo Total assets on NO side
    /// @return yesYield Yield allocated to YES stakers
    /// @return noYield Yield allocated to NO stakers
    function splitYieldWeighted(uint256 totalYield, uint256 twapAccumulatorYesDelta, uint256 timeDelta, uint256 assetsYes, uint256 assetsNo)
        internal
        pure
        returns (uint256 yesYield, uint256 noYield)
    {
        // Handle edge cases
        if (timeDelta == 0) return splitYieldEqual(totalYield);
        if (totalYield == 0) return (0, 0);
        if (assetsYes == 0 && assetsNo == 0) return splitYieldEqual(totalYield);
        if (assetsYes == 0) return (0, totalYield);
        if (assetsNo == 0) return (totalYield, 0);

        uint256 twapAccumulatorNoDelta = calculateTwapAccumulatorNo(twapAccumulatorYesDelta, timeDelta);

        // Calculate weighted values: assets * priceIndex
        // yesValue = assetsYes * twapAccumulatorYesDelta (proportional to assetsYes * avgYesPrice * time)
        // noValue = assetsNo * twapAccumulatorNoDelta (proportional to assetsNo * avgNoPrice * time)
        uint256 yesWeightedValue = assetsYes * twapAccumulatorYesDelta;
        uint256 noWeightedValue = assetsNo * twapAccumulatorNoDelta;
        uint256 totalWeightedValue = yesWeightedValue + noWeightedValue;

        if (totalWeightedValue == 0) return splitYieldEqual(totalYield);

        // Proportional split based on weighted values
        yesYield = totalYield.mulDiv(yesWeightedValue, totalWeightedValue, Math.Rounding.Floor);
        noYield = totalYield - yesYield; // Ensure no dust
    }

    /// @notice Calculate default 50:50 yield split (when Twap not required)
    /// @param totalYield Total yield to distribute
    /// @return yesYield Half of yield for YES
    /// @return noYield Half of yield for NO
    function splitYieldEqual(uint256 totalYield) internal pure returns (uint256 yesYield, uint256 noYield) {
        yesYield = totalYield / 2;
        noYield = totalYield - yesYield;
    }

    /// @notice Calculate the default Twap price (50:50)
    /// @return defaultPrice PRICE_SCALE / 2
    function defaultPrice() internal pure returns (uint256) {
        return DataTypes.PRICE_SCALE / 2;
    }

    /// @notice Process and validate a single Twap data entry
    /// @param data Twap data for a market
    /// @param lastUpdate Market's last Twap update timestamp
    function _validateTwapData(DataTypes.TwapData memory data, uint256 lastUpdate) internal view {
        // Validate timing with grace period
        if (!TwapMath.validateTwapTiming(data.startTimestamp, data.endTimestamp, lastUpdate, block.timestamp)) {
            revert IPsiTwapOracle.TwapTimestampInvalid(data.startTimestamp, data.endTimestamp, lastUpdate);
        }

        // Validate price range
        if (data.twapPriceYes > DataTypes.PRICE_SCALE) {
            revert IPsiTwapOracle.TwapPriceOutOfRange(data.twapPriceYes);
        }

        // NONCES are not needed for Twaps since replay attacks are not possible for the same timestamp
    }

    /// @notice Validate Twap data timing
    /// @param startTimestamp Start of Twap period
    /// @param endTimestamp End of Twap period
    /// @param lastUpdate Market's last Twap update timestamp
    /// @param currentTime Current block timestamp
    /// @return valid True if timing is valid
    function validateTwapTiming(uint256 startTimestamp, uint256 endTimestamp, uint256 lastUpdate, uint256 currentTime)
        internal
        pure
        returns (bool valid)
    {
        // Start must not be after last update (no gaps allowed)
        // It can be before it though, which will happen often if two users interact with the same market at the same time.
        // One user updates first and the second one can just submit the same twap data because applyTwap() only advances the accumulator since lastUpdate.
        if (startTimestamp > lastUpdate) return false;
        // End must not be in the future
        if (endTimestamp > currentTime) return false;
        // End must be after or equal to start
        if (endTimestamp < startTimestamp) return false;
        return true;
    }
}
