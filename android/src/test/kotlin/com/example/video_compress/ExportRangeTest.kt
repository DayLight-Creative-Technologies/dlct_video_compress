package com.example.video_compress

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [exportRangeUs]: the part of a video a compress exports, from startTime for
 * duration seconds, cut at the end; the rule iOS and macOS apply too
 * (`AvController.exportRange`, checked by native_tests/media_info). The
 * plugin passes the source's length minus the range's end to
 * TrimDataSource as the part to cut from the end (SSK gap #913: it passed
 * the duration there).
 */
class ExportRangeTest {
    private val threeSeconds = 3_000_000L

    @Test
    fun noArgumentsIsTheWholeVideo() {
        assertEquals(Pair(0L, threeSeconds), exportRangeUs(null, null, threeSeconds))
    }

    @Test
    fun aStartAloneRunsToTheEnd() {
        assertEquals(Pair(2_000_000L, threeSeconds), exportRangeUs(2, null, threeSeconds))
    }

    @Test
    fun aDurationAloneStartsAtZero() {
        assertEquals(Pair(0L, 2_000_000L), exportRangeUs(null, 2, threeSeconds))
    }

    @Test
    fun aStartAndADuration() {
        assertEquals(Pair(1_000_000L, 2_000_000L), exportRangeUs(1, 1, threeSeconds))
    }

    @Test
    fun aDurationPastTheEndIsCutAtTheEnd() {
        assertEquals(Pair(1_000_000L, threeSeconds), exportRangeUs(1, 5, threeSeconds))
    }

    @Test
    fun aStartAtOrPastTheEndIsNoPart() {
        assertNull(exportRangeUs(3, null, threeSeconds))
        assertNull(exportRangeUs(4, 1, threeSeconds))
    }

    @Test
    fun aNegativeStartIsNoPart() {
        assertNull(exportRangeUs(-1, null, threeSeconds))
    }

    @Test
    fun aDurationThatIsNotPositiveIsNoPart() {
        assertNull(exportRangeUs(0, 0, threeSeconds))
        assertNull(exportRangeUs(null, -1, threeSeconds))
    }

    @Test
    fun aStartPast2To31SecondsIsNotTruncated() {
        val long = 5_000_000_000L * 1_000_000L
        assertEquals(Pair(3_000_000_000L * 1_000_000L, long), exportRangeUs(3_000_000_000L, null, long))
    }
}
