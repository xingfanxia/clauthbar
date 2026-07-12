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

        // today: in_out is the headline basis; cost is a known (non-floor) amount.
        XCTAssertEqual(t.periods.today.inOut, 41_200_000)
        XCTAssertEqual(t.periods.today.total, 577_200_000)
        XCTAssertEqual(t.periods.today.costUsd, 12.40)
        XCTAssertFalse(t.periods.today.costIsFloor)
        XCTAssertTrue(t.periods.today.complete)

        // month is the floor case — the strip must render "$268.50+".
        XCTAssertTrue(t.periods.month.costIsFloor)
        XCTAssertEqual(MachineTokens.formatCost(t.periods.month.costUsd, isFloor: t.periods.month.costIsFloor), "$268.50+")

        // lifetime crosses into billions and is still accumulating.
        XCTAssertEqual(t.periods.lifetime.inOut, 3_120_000_000)
        XCTAssertFalse(t.periods.lifetime.complete)
        XCTAssertEqual(MachineTokens.abbreviateCount(t.periods.lifetime.inOut), "3.12B")

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

    func testTopModelsIsAPrefix() throws {
        let t = try decode(#"""
        {"schema":1,"generated_at":"2026-07-04T05:00:00+00:00",
         "periods":{"today":{"in_out":60,"models":[
            {"model":"a","in_out":30},{"model":"b","in_out":20},
            {"model":"c","in_out":7},{"model":"others","in_out":3}]}}}
        """#)
        XCTAssertEqual(t.periods.today.topModels(3).map(\.model), ["a", "b", "c"])
        // Fewer models than n → the whole list, no crash.
        XCTAssertEqual(t.periods.today.topModels(10).count, 4)
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
