import Foundation
import XCTest

@testable import CCSBarKit

/// The tokens.json contract (TOK-4): the bundled fixture must decode through
/// `MachineTokens`, the additive leniency an older/newer daemon relies on holds, the
/// schema gate reads a future shape's version without a full decode, and the pure
/// formatters + model-basis selection are pinned so a "cleanup" can't silently drift
/// them (they render every number in the strip).
final class MachineTokensTests: XCTestCase {
    private func decode(_ json: String) throws -> MachineTokens {
        try JSONDecoder().decode(MachineTokens.self, from: Data(json.utf8))
    }

    // MARK: Contract — the bundled fixture decodes and matches known values.

    func testBundledFixtureDecodes() throws {
        let data = try XCTUnwrap(Fixtures.tokensJSONData(), "tokens fixture resource must be bundled")
        let t = try JSONDecoder().decode(MachineTokens.self, from: data)
        XCTAssertEqual(t.schema, 1)
        XCTAssertEqual(t.clauthVersion, "0.9.0")
        XCTAssertEqual(t.toppedUpThrough, "2026-07-01")

        // today: the cache-INCLUSIVE total is the headline display basis (the cost
        // beside it always prices cache tokens); in_out stays decoded for contract
        // fidelity. Cost is a known (non-floor) amount.
        XCTAssertEqual(t.periods.today.inOut, 41_200_000)
        XCTAssertEqual(t.periods.today.total, 577_200_000)
        XCTAssertEqual(t.periods.today.displayTokens, 577_200_000)
        XCTAssertEqual(t.periods.today.costUsd, 12.40)
        XCTAssertFalse(t.periods.today.costIsFloor)
        XCTAssertTrue(t.periods.today.complete)

        // month is the floor window (matches the live writer: week/month fold
        // stats-cache days that published only combined in+out, so their buckets —
        // and `total` — undercount): BOTH the count and the cost decorate a "+".
        XCTAssertFalse(t.periods.month.complete)
        XCTAssertTrue(t.periods.month.costIsFloor)
        XCTAssertEqual(
            MachineTokens.formatCount(t.periods.month.displayTokens, isFloor: !t.periods.month.complete),
            "11.7B+")
        XCTAssertEqual(MachineTokens.formatCost(t.periods.month.costUsd, isFloor: t.periods.month.costIsFloor), "$268.50+")

        // lifetime crosses into tens of billions. Its rows come from the stats-cache
        // lifetime aggregates, which always carry full splits — so the COUNT is exact
        // (no "+"), while the COST still floors on an unpriced model. The two floor
        // flags are independent.
        XCTAssertEqual(t.periods.lifetime.inOut, 3_120_000_000)
        XCTAssertEqual(t.periods.lifetime.displayTokens, 43_140_000_000)
        XCTAssertTrue(t.periods.lifetime.complete)
        XCTAssertTrue(t.periods.lifetime.costIsFloor)
        XCTAssertEqual(
            MachineTokens.formatCount(t.periods.lifetime.displayTokens, isFloor: !t.periods.lifetime.complete),
            "43.1B")

        // models are DESC by in_out with the tail pre-folded into an "others" row.
        let today = t.periods.today.models
        XCTAssertEqual(today.map(\.model), ["claude-fable-5", "claude-opus-4-8", "claude-haiku-4-5", "others"])
        XCTAssertEqual(today.first?.display, "Fable 5")
        XCTAssertEqual(today.map(\.inOut), today.map(\.inOut).sorted(by: >), "models must stay DESC by in_out")
        XCTAssertFalse(try XCTUnwrap(today.last).splitComplete, "the others row folds an unattributed tail")
    }

    // MARK: Leniency — additive-era survival (missing fields / missing periods).

    func testPeriodDecodesWithSparseFields() throws {
        // A period carrying only in_out: every other count defaults to 0, complete
        // defaults true, cost is nil, models empty — never a throw that hides the strip.
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":5000}}}
        """#)
        XCTAssertEqual(t.periods.today.inOut, 5000)
        XCTAssertEqual(t.periods.today.input, 0)
        XCTAssertEqual(t.periods.today.total, 0)
        XCTAssertTrue(t.periods.today.complete)
        XCTAssertNil(t.periods.today.costUsd)
        XCTAssertFalse(t.periods.today.costIsFloor)
        XCTAssertTrue(t.periods.today.models.isEmpty)
        // Missing period keys decode as empty windows, not a decode failure.
        XCTAssertEqual(t.periods.week.inOut, 0)
        XCTAssertEqual(t.periods.lifetime.inOut, 0)
    }

    func testModelDisplayFallsBackToModelId() throws {
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":10,"models":[{"model":"claude-x","in_out":10}]}}}
        """#)
        let m = try XCTUnwrap(t.periods.today.models.first)
        XCTAssertEqual(m.display, "claude-x", "absent display falls back to the model id")
        XCTAssertTrue(m.splitComplete, "absent split_complete defaults true")
    }

    func testMissingPeriodsThrows() {
        // `periods` is load-bearing (like `profiles` in DaemonStatus) — its absence is
        // a malformed file, which readTokens catches as .decodeFailed → hidden strip.
        XCTAssertThrowsError(try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00"}
        """#))
    }

    func testMalformedBodyFailsToDecode() {
        // The .decodeFailed path: a body that isn't a valid MachineTokens must throw
        // (readTokens logs + returns .decodeFailed, and the caller hides the strip).
        XCTAssertThrowsError(try decode("{ not json"))
    }

    // MARK: Display basis — cache-INCLUSIVE totals. The strip's counts must track the
    // dollar figure beside them: cost always prices cache tokens, and under 1h-TTL
    // prompt caching in_out is a fraction of a percent of billed volume ("1.03M ·
    // $319" read as a broken counter — the 2026-07-12 bug report this section pins).

    func testPeriodDisplayTokensIsCacheInclusiveTotal() throws {
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"input":10,"output":20,"cache_read":900,"cache_create":70,
                             "in_out":30,"total":1000}}}
        """#)
        XCTAssertEqual(t.periods.today.displayTokens, 1000, "total (incl. cache) is the display basis")
    }

    func testPeriodDisplayTokensFallsBackToInOutWhenTotalAbsent() throws {
        // An older writer that never published `total` (leniency default 0) must not
        // blank the strip to "0" — in_out is the best available floor.
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":5000}}}
        """#)
        XCTAssertEqual(t.periods.today.displayTokens, 5000)
    }

    func testModelDisplayTokensSumsAllFourBuckets() throws {
        // Models carry no `total` field — the display total is the client-side sum of
        // the four buckets, falling back to in_out when the split is absent.
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":30,"total":1000,"models":[
            {"model":"a","input":10,"output":20,"cache_read":900,"cache_create":70,"in_out":30},
            {"model":"b","in_out":40}]}}}
        """#)
        XCTAssertEqual(t.periods.today.models[0].displayTokens, 1000)
        XCTAssertEqual(t.periods.today.models[1].displayTokens, 40, "split-less model row falls back to in_out")
    }

    func testModelDisplayTokensSaturatesInsteadOfTrapping() throws {
        // A corrupt/hostile file with near-max buckets must saturate, never overflow-
        // trap the menu bar app (same never-crash discipline as the decode leniency).
        let big = UInt64.max - 5
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":1,"total":1,"models":[
            {"model":"a","input":\#(big),"output":\#(big),"cache_read":\#(big),"cache_create":\#(big),"in_out":1}]}}}
        """#)
        XCTAssertEqual(t.periods.today.models[0].displayTokens, UInt64.max)
    }

    // MARK: Formatters — count with floor decoration (mirrors formatCost's "+").

    func testFormatCountPins() {
        XCTAssertEqual(MachineTokens.formatCount(577_200_000), "577M")
        XCTAssertEqual(MachineTokens.formatCount(5_470_000_000, isFloor: true), "5.47B+")
        XCTAssertEqual(MachineTokens.formatCount(0, isFloor: true), "0", "a zero count never reads \"0+\"")
    }

    // MARK: Schema gate — reads the version alone from a future shape, independent of
    // status.json's supportedSchema.

    func testTokensSchemaProbeReadsFutureShape() throws {
        let probe = try JSONDecoder().decode(
            SchemaProbe.self,
            from: Data(#"{"schema": 2, "periods": "totally different"}"#.utf8)
        )
        XCTAssertEqual(probe.schema, 2)
        XCTAssertNotEqual(probe.schema, supportedTokensSchema, "a schema-2 file is rejected by the gate")
    }

    // MARK: Model-basis selection — TODAY when it has usage, else LIFETIME.

    func testModelsBasisPrefersTodayWhenItHasUsage() throws {
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":10,"models":[{"model":"a","in_out":10}]},
                    "lifetime":{"in_out":99,"models":[{"model":"z","in_out":99}]}}}
        """#)
        XCTAssertEqual(t.modelsBasis, .today)
        XCTAssertEqual(t.modelsPeriod.models.first?.model, "a")
    }

    func testModelsBasisCountsCacheOnlyUsageAsToday() throws {
        // A day of pure cache traffic (in_out 0 but total > 0) is still usage —
        // the basis keys on the same cache-inclusive count the strip displays.
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":0,"total":500,"models":[{"model":"a","cache_read":500}]},
                    "lifetime":{"in_out":99,"models":[{"model":"z","in_out":99}]}}}
        """#)
        XCTAssertEqual(t.modelsBasis, .today)
    }

    func testModelsBasisFallsBackToLifetimeWhenTodayEmpty() throws {
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":0},
                    "lifetime":{"in_out":99,"models":[{"model":"z","display":"Z","in_out":99}]}}}
        """#)
        XCTAssertEqual(t.modelsBasis, .lifetime)
        XCTAssertEqual(t.modelsBasis.rawValue, "LIFETIME")
        XCTAssertEqual(t.modelsPeriod.models.first?.display, "Z")
    }

    func testTopModelsRanksByDisplayTokensWithOthersLast() throws {
        // The daemon orders rows DESC by in_out, but the strip renders cache-
        // inclusive counts — a cache-heavy model must not read out of order.
        // Here "b" leads on in_out (40 > 30) but "a" dominates once cache counts
        // (1000), and the folded "others" row stays pinned last regardless.
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":70,"total":1040,"models":[
            {"model":"b","in_out":40},
            {"model":"a","input":10,"output":20,"cache_read":900,"cache_create":70,"in_out":30},
            {"model":"others","in_out":3,"cache_read":2000,"split_complete":false}]}}}
        """#)
        XCTAssertEqual(t.periods.today.topModels(3).map(\.model), ["a", "b", "others"])
        // Fewer models than n → the whole list, no crash.
        XCTAssertEqual(t.periods.today.topModels(10).count, 3)
    }

    func testTopModelsKeepsDaemonOrderOnEqualCounts() throws {
        // Equal display counts keep the daemon's in_out-DESC order (stable sort).
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":60,"models":[
            {"model":"a","in_out":30},{"model":"b","in_out":30},{"model":"c","in_out":7}]}}}
        """#)
        XCTAssertEqual(t.periods.today.topModels(3).map(\.model), ["a", "b", "c"])
    }

    // MARK: Formatters — token abbreviation (3 significant figures, K/M/B).

    func testAbbreviateCountPins() {
        XCTAssertEqual(MachineTokens.abbreviateCount(0), "0")
        XCTAssertEqual(MachineTokens.abbreviateCount(999), "999")
        XCTAssertEqual(MachineTokens.abbreviateCount(1_000), "1.00K")
        XCTAssertEqual(MachineTokens.abbreviateCount(12_400), "12.4K")
        XCTAssertEqual(MachineTokens.abbreviateCount(123_000), "123K")
        XCTAssertEqual(MachineTokens.abbreviateCount(41_200_000), "41.2M")
        XCTAssertEqual(MachineTokens.abbreviateCount(1_240_000_000), "1.24B")
    }

    func testAbbreviateCountRoundingPromotesUnit() {
        // 999.95K rounds to a full 1000 at 0 decimals — must promote to "1.00M",
        // never read "1000K".
        XCTAssertEqual(MachineTokens.abbreviateCount(999_950), "1.00M")
        // Exactly a unit boundary reads in the larger unit.
        XCTAssertEqual(MachineTokens.abbreviateCount(1_000_000), "1.00M")
        XCTAssertEqual(MachineTokens.abbreviateCount(1_000_000_000), "1.00B")
    }

    func testAbbreviateCountRoundingCrossesDigitBands() {
        // Rounding that crosses a digit band inside the SAME unit must re-derive
        // the precision from the rounded value — never print a fourth
        // significant figure ("10.00K" / "100.0K").
        XCTAssertEqual(MachineTokens.abbreviateCount(9_999), "10.0K")
        XCTAssertEqual(MachineTokens.abbreviateCount(99_950), "100K")
        XCTAssertEqual(MachineTokens.abbreviateCount(9_999_000), "10.0M")
        XCTAssertEqual(MachineTokens.abbreviateCount(99_950_000), "100M")
    }

    // MARK: Formatters — cost ($X, floor $X+, sub-cent, zero, nil).

    func testFormatCostPins() {
        XCTAssertEqual(MachineTokens.formatCost(8.21), "$8.21")
        XCTAssertEqual(MachineTokens.formatCost(8.21, isFloor: true), "$8.21+")
        XCTAssertEqual(MachineTokens.formatCost(268.50, isFloor: true), "$268.50+")
        XCTAssertEqual(MachineTokens.formatCost(0.004), "<$0.01")
        // A sub-cent floor still reads "<$0.01" — the "+" only decorates a shown amount.
        XCTAssertEqual(MachineTokens.formatCost(0.004, isFloor: true), "<$0.01")
        XCTAssertEqual(MachineTokens.formatCost(0), "$0.00")
        XCTAssertEqual(MachineTokens.formatCost(nil), "—")
    }
}
