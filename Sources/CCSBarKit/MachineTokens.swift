import Foundation

/// The `tokens.json` schema this ccsbar build understands. It is INDEPENDENT of
/// `status.json`'s `supportedSchema` (the two files version separately): a newer
/// daemon may bump one without the other. The gate turns an unrecognised on-disk
/// `schema` into a quietly-hidden strip, never a misparse or a crash — the token
/// strip is machine context, so a version gap simply drops it until ccsbar updates.
let supportedTokensSchema = 1

/// Mirror of `~/.clauth/tokens.json` (schema 1), written by `clauth daemon`.
///
/// MACHINE-WIDE token usage — Claude Code's LOCAL history across ALL accounts on
/// this machine, NOT a per-profile figure. The CACHE-INCLUSIVE `total` is the
/// display basis (see `displayTokens`): the cost beside every count always prices
/// cache tokens, and under 1h-TTL prompt caching `in_out` (input + output only) is
/// a fraction of a percent of billed volume — headlining it made the strip read
/// "1.03M · $319". See clauth's tokens snapshot writer for the authoritative
/// shape. Decoded with the same additive
/// discipline as `DaemonStatus`: fields the daemon adds later are `decodeIfPresent`
/// with benign defaults so an older/newer writer never blanks the strip.
struct MachineTokens: Codable, Sendable {
    let schema: Int
    let generatedAt: String
    let clauthVersion: String?
    /// The date (YYYY-MM-DD) through which the daemon's transcript top-up sweep has
    /// folded Claude Code's session logs into the snapshot — a data-completeness
    /// marker, or nil before the first sweep finishes. Not surfaced yet; decoded for
    /// contract fidelity.
    let toppedUpThrough: String?
    let periods: Periods

    enum CodingKeys: String, CodingKey {
        case schema
        case generatedAt = "generated_at"
        case clauthVersion = "clauth_version"
        case toppedUpThrough = "topped_up_through"
        case periods
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        generatedAt = try c.decode(String.self, forKey: .generatedAt)
        clauthVersion = try c.decodeIfPresent(String.self, forKey: .clauthVersion)
        toppedUpThrough = try c.decodeIfPresent(String.self, forKey: .toppedUpThrough)
        periods = try c.decode(Periods.self, forKey: .periods)
    }

    // MARK: - Model breakdown source

    /// Which period the hover detail lists models from: TODAY when it has any usage,
    /// else LIFETIME — a machine with nothing logged yet today still shows a
    /// meaningful breakdown instead of an empty block.
    enum ModelsBasis: String { case today = "TODAY", lifetime = "LIFETIME" }

    var modelsBasis: ModelsBasis { periods.today.displayTokens > 0 ? .today : .lifetime }
    var modelsPeriod: TokenPeriod { modelsBasis == .today ? periods.today : periods.lifetime }
}

/// The four rollup windows tokens.json always carries. Each is `decodeIfPresent`
/// with an empty default so a future writer that adds/removes a window can't throw
/// and hide the whole strip.
struct Periods: Codable, Sendable {
    let today: TokenPeriod
    let week: TokenPeriod
    let month: TokenPeriod
    let lifetime: TokenPeriod

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        today = try c.decodeIfPresent(TokenPeriod.self, forKey: .today) ?? .empty
        week = try c.decodeIfPresent(TokenPeriod.self, forKey: .week) ?? .empty
        month = try c.decodeIfPresent(TokenPeriod.self, forKey: .month) ?? .empty
        lifetime = try c.decodeIfPresent(TokenPeriod.self, forKey: .lifetime) ?? .empty
    }
}

/// One rollup window's token counts + cost. `costUsd` is nil when the daemon can't
/// price the window; `costIsFloor` marks a lower-bound estimate (some usage couldn't
/// be attributed to a priced model) → render "$X+". `models` is DESC by `in_out`,
/// ≤ 8 rows, with the daemon having pre-folded the remainder into an `"others"` row.
struct TokenPeriod: Codable, Sendable {
    let from: String?
    let to: String?
    let input: UInt64
    let output: UInt64
    let cacheRead: UInt64
    let cacheCreate: UInt64
    let inOut: UInt64
    let total: UInt64
    let complete: Bool
    let costUsd: Double?
    let costIsFloor: Bool
    let models: [TokenModel]

    enum CodingKeys: String, CodingKey {
        case from, to, input, output, total, complete, models
        case cacheRead = "cache_read"
        case cacheCreate = "cache_create"
        case inOut = "in_out"
        case costUsd = "cost_usd"
        case costIsFloor = "cost_is_floor"
    }

    /// A zeroed window — the `Periods` default for a missing key (never rendered in
    /// practice; the daemon writes all four).
    private init() {
        from = nil; to = nil
        input = 0; output = 0; cacheRead = 0; cacheCreate = 0; inOut = 0; total = 0
        complete = true; costUsd = nil; costIsFloor = false; models = []
    }
    static let empty = TokenPeriod()

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        input = try c.decodeIfPresent(UInt64.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(UInt64.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(UInt64.self, forKey: .cacheRead) ?? 0
        cacheCreate = try c.decodeIfPresent(UInt64.self, forKey: .cacheCreate) ?? 0
        inOut = try c.decodeIfPresent(UInt64.self, forKey: .inOut) ?? 0
        total = try c.decodeIfPresent(UInt64.self, forKey: .total) ?? 0
        complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
        costIsFloor = try c.decodeIfPresent(Bool.self, forKey: .costIsFloor) ?? false
        models = try c.decodeIfPresent([TokenModel].self, forKey: .models) ?? []
    }

    /// The count the strip renders — CACHE-INCLUSIVE, so the token figure moves with
    /// the dollar figure beside it (cost always prices cache tokens). `total` is the
    /// daemon's four-bucket sum; an older writer that omitted it falls back to
    /// `in_out` (a floor, but never a blanked-out 0 — note that legacy path renders
    /// cache-excluded with no "+", since `complete` defaults true; acceptable decay
    /// for pre-`total` snapshots only). When `complete` is false the buckets
    /// undercount, so render this with `formatCount(_:isFloor: !complete)`.
    var displayTokens: UInt64 { max(total, inOut) }

    /// The first `n` models for display. The daemon sorts DESC by `in_out` and folds
    /// the long tail into one `"others"` row — but the strip renders cache-INCLUSIVE
    /// counts, and a cache-heavy model can out-total a row the daemon put above it.
    /// Re-rank by `displayTokens` so the visible numbers read monotonic, keep the
    /// folded `"others"` sentinel pinned last, and break ties by the daemon's order
    /// (`enumerated` keeps the sort deterministic; `sorted` alone isn't stable).
    func topModels(_ n: Int) -> [TokenModel] {
        let ranked = models.enumerated().sorted { a, b in
            let aOthers = a.element.model == TokenModel.foldedTailID
            let bOthers = b.element.model == TokenModel.foldedTailID
            if aOthers != bOthers { return bOthers }
            if a.element.displayTokens != b.element.displayTokens {
                return a.element.displayTokens > b.element.displayTokens
            }
            return a.offset < b.offset
        }
        return Array(ranked.map(\.element).prefix(n))
    }
}

/// One model's share of a period. `display` is the human label ("Fable 5"); `model`
/// is the raw id (or the sentinel `"others"` for the folded remainder). Models carry
/// no floor flag — the period owns that.
struct TokenModel: Codable, Sendable, Identifiable {
    /// The daemon's sentinel `model` id for the folded long-tail row — display-
    /// ranked last by `topModels` no matter its count.
    static let foldedTailID = "others"

    var id: String { model }
    let model: String
    let display: String
    let input: UInt64
    let output: UInt64
    let cacheRead: UInt64
    let cacheCreate: UInt64
    let inOut: UInt64
    let splitComplete: Bool
    let costUsd: Double?

    enum CodingKeys: String, CodingKey {
        case model, display, input, output
        case cacheRead = "cache_read"
        case cacheCreate = "cache_create"
        case inOut = "in_out"
        case splitComplete = "split_complete"
        case costUsd = "cost_usd"
    }

    /// The model row's cache-inclusive count (same basis as `TokenPeriod
    /// .displayTokens`). Models carry no `total` field, so this sums the four
    /// buckets — saturating, because a corrupt file must never overflow-trap the
    /// menu bar app — and falls back to `in_out` when the split is absent/partial
    /// (`in_out` can exceed a partial split's sum; `split_complete` marks that and
    /// drives the "+" — a legacy writer omitting buckets while `split_complete`
    /// defaults true under-decorates, same acceptable decay as the period side).
    var displayTokens: UInt64 {
        let split = [output, cacheRead, cacheCreate].reduce(input) { acc, n in
            let (sum, overflow) = acc.addingReportingOverflow(n)
            return overflow ? .max : sum
        }
        return max(split, inOut)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model)
        display = try c.decodeIfPresent(String.self, forKey: .display) ?? model
        input = try c.decodeIfPresent(UInt64.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(UInt64.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(UInt64.self, forKey: .cacheRead) ?? 0
        cacheCreate = try c.decodeIfPresent(UInt64.self, forKey: .cacheCreate) ?? 0
        inOut = try c.decodeIfPresent(UInt64.self, forKey: .inOut) ?? 0
        splitComplete = try c.decodeIfPresent(Bool.self, forKey: .splitComplete) ?? true
        costUsd = try c.decodeIfPresent(Double.self, forKey: .costUsd)
    }
}

// MARK: - Formatting (pure — pinned in tests)

extension MachineTokens {
    /// Abbreviate a token count to 3 significant figures with a K/M/B suffix:
    /// `999 → "999"`, `12_400 → "12.4K"`, `41_200_000 → "41.2M"`,
    /// `1_240_000_000 → "1.24B"`. Under 1000 renders the exact integer. Rounding that
    /// crosses a digit band re-derives the precision from the ROUNDED value
    /// (`9_999 → "10.0K"`, `99_950 → "100K"`, never `"10.00K"`/`"100.0K"`), and
    /// rounding that reaches a full 1000 promotes to the next unit
    /// (`999_950 → "1.00M"`) so a strip never reads "1000K".
    static func abbreviateCount(_ n: UInt64) -> String {
        if n < 1_000 { return String(n) }
        let value = Double(n)
        let units: [(div: Double, suffix: String)] = [(1e3, "K"), (1e6, "M"), (1e9, "B")]
        for (i, unit) in units.enumerated() {
            let mantissa = value / unit.div
            let hasNext = i + 1 < units.count
            // This value belongs in a larger unit — skip unless we're already at B.
            if mantissa >= 1_000, hasNext { continue }
            var decimals = mantissa >= 100 ? 0 : (mantissa >= 10 ? 1 : 2)
            var s = String(format: "%.\(decimals)f", mantissa)
            // Rounding can push the printed value into a higher digit band
            // (9.999 → "10.00", 99.95 → "100.0" — four significant figures);
            // re-derive the precision from the rounded value until stable.
            while decimals > 0, let rounded = Double(s),
                rounded >= (decimals == 2 ? 10 : 100)
            {
                decimals -= 1
                s = String(format: "%.\(decimals)f", mantissa)
            }
            // Rounding reached a full 1000 — promote to the next unit.
            if s == "1000", hasNext { continue }
            return s + unit.suffix
        }
        return String(n) // unreachable (B always returns above); defensive terminal
    }

    /// Format a token count for display: `abbreviateCount` plus the same "+" floor
    /// decoration costs use — an incomplete period's buckets undercount (a stats-cache
    /// day may have published only combined in+out), so `577M` vs `5.47B+` mirrors
    /// `$12.40` vs `$268.50+`. A zero count never reads "0+".
    static func formatCount(_ n: UInt64, isFloor: Bool = false) -> String {
        let base = abbreviateCount(n)
        return (isFloor && n > 0) ? base + "+" : base
    }

    /// Format a cost: `8.21 → "$8.21"`, floor → `"$8.21+"`, sub-cent `(0, 0.01) →
    /// "<$0.01"`, exact zero → `"$0.00"`, nil → `"—"`. A sub-cent floor still reads
    /// `"<$0.01"` (the "+" only decorates a displayable ≥ 1¢ amount).
    static func formatCost(_ cost: Double?, isFloor: Bool = false) -> String {
        guard let cost else { return "—" }
        if cost <= 0 { return "$0.00" }
        if cost < 0.01 { return "<$0.01" }
        let base = String(format: "$%.2f", cost)
        return isFloor ? base + "+" : base
    }
}
