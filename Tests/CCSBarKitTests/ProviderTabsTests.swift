import Foundation
import XCTest

@testable import CCSBarKit

/// TABS-1: the provider tab model, harness routing, the codex login CLI shapes,
/// and the harness-aware switch behavior — pure decisions over injected status.
final class ProviderTabsTests: XCTestCase {
    // A status with one profile per harness, both slots active, both chains real.
    // Positions are 1-BASED, matching the daemon wire contract (status_json.rs
    // emits `pos + 1`).
    private func twoHarnessStatus(
        claudeLive: Bool = false, codexLimited: String? = nil
    ) throws -> DaemonStatus {
        let limited = codexLimited.map { "\"codex_rate_limit_reached\":\"\($0)\"," } ?? ""
        return try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"cl-a",
         "wrap_off":false,"refresh_interval_ms":90000,
         "fallback_chain":["cl-a","cl-b"],
         "active_codex_profile":"cx-a","codex_fallback_chain":["cx-a","cx-b"],
         "profiles":[
           {"name":"cl-a","active":true,"has_live_session":\(claudeLive),
            "fallback":{"position":1,"threshold":95,"armed":true},
            "windows":[{"label":"5h","utilization_pct":40,"resets_at":"2099-01-01T05:00:00+00:00"}]},
           {"name":"cl-b","active":false,
            "fallback":{"position":2,"threshold":95,"armed":false},"windows":[]},
           {"name":"cx-a","active":true,"provider":"openai","harness":"codex",\(limited)
            "fallback":{"position":1,"threshold":95,"armed":true},
            "windows":[{"label":"5h","utilization_pct":80,"resets_at":"2099-01-01T05:00:00+00:00"},
                       {"label":"7d","utilization_pct":30,"resets_at":"2099-01-06T00:00:00+00:00"}]},
           {"name":"cx-b","active":false,"provider":"openai","harness":"codex",
            "fallback":{"position":2,"threshold":95,"armed":false},"windows":[]}
         ]}
        """.utf8))
    }

    // MARK: - ProviderTab

    func testTabHarnessMappingAndPersistabilityAreTotal() {
        XCTAssertNil(ProviderTab.overview.harness)
        XCTAssertEqual(ProviderTab.claude.harness, .claude)
        XCTAssertEqual(ProviderTab.codex.harness, .codex)
        for tab in ProviderTab.allCases {
            // rawValue round-trips (the UserDefaults persistence path) and every
            // tab has a non-empty title + symbol (the bar renders all of them).
            XCTAssertEqual(ProviderTab(rawValue: tab.rawValue), tab)
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertFalse(tab.symbol.isEmpty)
        }
    }

    @MainActor
    func testTabChangeResetsInspection() throws {
        let model = StatusModel(preview: try twoHarnessStatus(), inspected: "cl-b", tab: .claude)
        XCTAssertEqual(model.inspected?.name, "cl-b")
        model.tab = .codex
        XCTAssertNil(model.inspectedName, "inspection is per-page view state")
        // On the codex page the fallback resolution lands on the CODEX active slot.
        XCTAssertEqual(model.inspected?.name, "cx-a")
    }

    // MARK: - Harness filters

    @MainActor
    func testHarnessScopedProfileAndActiveAccessors() throws {
        let model = StatusModel(preview: try twoHarnessStatus())
        XCTAssertEqual(model.profiles(for: .claude).map(\.name), ["cl-a", "cl-b"])
        XCTAssertEqual(model.profiles(for: .codex).map(\.name), ["cx-a", "cx-b"])
        XCTAssertEqual(model.activeProfile(for: .claude)?.name, "cl-a")
        XCTAssertEqual(model.activeProfile(for: .codex)?.name, "cx-a")
    }

    // MARK: - chainLine (position is 1-based on the wire — NO +1)

    @MainActor
    func testChainLineUsesHarnessScopedOrdinals() throws {
        let s = try twoHarnessStatus()
        let model = StatusModel(preview: s)
        // Codex chain head reads "1st" straight off position=1 — the codex chain,
        // not an index into the claude chain (where cx-a doesn't exist at all).
        let cxa = try XCTUnwrap(s.profiles.first { $0.name == "cx-a" })
        XCTAssertEqual(model.chainLine(for: cxa),
                       "1st in chain · leaves at 95% of the 5h window",
                       "active codex gets the plain line — no claude forecast clause")
        let cxb = try XCTUnwrap(s.profiles.first { $0.name == "cx-b" })
        XCTAssertEqual(model.chainLine(for: cxb),
                       "2nd in chain · leaves at 95% of the 5h window")
    }

    // MARK: - Harness-aware switch

    @MainActor
    func testCodexSwitchNeverArmsAndConfirmsOffCodexSlot() throws {
        // Claude active has a LIVE session — a claude switch would arm. The codex
        // switch must ignore it (nothing a codex confirm protects) and go straight
        // to pending.
        let model = StatusModel(preview: try twoHarnessStatus(claudeLive: true))
        model.switchTo("cx-b")
        XCTAssertEqual(model.switchHarness, .codex)
        guard case .pending(let target) = model.switchPhase else {
            return XCTFail("codex switch must skip arming, got \(model.switchPhase)")
        }
        XCTAssertEqual(target, "cx-b")
        // The codex slot advancing to the target confirms; the CLAUDE slot is
        // what the pre-TABS-1 code watched, and it never changes here.
        model.dispatch(.observedActive("cx-b"))
        guard case .confirmed = model.switchPhase else {
            return XCTFail("observing the codex slot must confirm, got \(model.switchPhase)")
        }
        model.dismissSwitch()
    }

    @MainActor
    func testClaudeSwitchWithLiveSessionStillArms() throws {
        let model = StatusModel(preview: try twoHarnessStatus(claudeLive: true))
        model.switchTo("cl-b")
        XCTAssertEqual(model.switchHarness, .claude)
        guard case .arming = model.switchPhase else {
            return XCTFail("claude live-session switch must arm, got \(model.switchPhase)")
        }
        model.dismissSwitch()
    }

    // MARK: - Login CLI shapes

    func testLoginArgsShapes() {
        XCTAssertEqual(DaemonClient.loginArgs("x", newOnly: false, codex: false, browser: true),
                       ["login", "x"])
        XCTAssertEqual(DaemonClient.loginArgs("x", newOnly: true, codex: false, browser: true),
                       ["login", "--new", "x"])
        XCTAssertEqual(DaemonClient.loginArgs("x", newOnly: true, codex: true, browser: false),
                       ["login", "--new", "x", "--codex"],
                       "codex capture: --codex, NO --browser")
        XCTAssertEqual(DaemonClient.loginArgs("x", newOnly: false, codex: true, browser: true),
                       ["login", "x", "--codex", "--browser"])
        XCTAssertEqual(DaemonClient.loginArgs("x", newOnly: false, codex: false, browser: false),
                       ["login", "x"],
                       "browser flag is codex-only on the CLI — never emitted bare")
    }

    func testLoginFailureMessageNamesTheExactCLI() {
        // Codex browser reauth failure hints the full codex CLI shape.
        let browser = StatusModel.loginFailureMessage(
            .daemonError(code: "cli_failed", message: "exit 1"),
            name: "cx", codex: true, mode: .browser)
        XCTAssertTrue(browser?.contains("clauth login cx --codex --browser") == true, "\(browser ?? "nil")")
        // Capture failure must NOT read as a browser problem.
        let capture = StatusModel.loginFailureMessage(
            .daemonError(code: "cli_failed", message: "exit 1"),
            name: "cx", codex: true, mode: .capture)
        XCTAssertTrue(capture?.contains("Couldn't capture the codex login") == true, "\(capture ?? "nil")")
        XCTAssertTrue(capture?.contains("clauth login cx --codex") == true)
        XCTAssertFalse(capture?.contains("--browser") == true)
        // The claude default keeps its pre-TABS-1 copy exactly.
        XCTAssertEqual(
            StatusModel.loginFailureMessage(.unreachable, name: "a"),
            "Couldn't find the clauth binary. Run `clauth login a` in a terminal.")
    }

    @MainActor
    func testCodexAddAccountThreadsModeAndFlight() async throws {
        let model = StatusModel(preview: try twoHarnessStatus())
        model.beginAddAccount(.codex)
        XCTAssertEqual(model.addingHarness, .codex)
        model.addAccount("cx-new", codex: true, mode: .capture, run: { _ in .ok })
        XCTAssertNil(model.addingHarness, "editor collapses on submit")
        XCTAssertEqual(model.loginInFlight, LoginFlight(name: "cx-new", mode: .capture),
                       "flight carries the CAPTURE mode — the banner must not say 'browser'")
        // Drain the completion.
        for _ in 0..<200 {
            if model.loginInFlight == nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.loginInFlight)
    }

    @MainActor
    func testPendingSwitchProtectsHarnessFromASecondRequest() throws {
        // Review HIGH: a mid-pending switchTo must not clobber switchHarness — the
        // in-flight confirm ladder reads it to pick which active slot to observe,
        // so a clobber false-fails a switch that succeeded.
        let model = StatusModel(preview: try twoHarnessStatus())
        model.switchTo("cl-b")
        XCTAssertEqual(model.switchHarness, .claude)
        guard case .pending("cl-b") = model.switchPhase else {
            return XCTFail("expected pending cl-b, got \(model.switchPhase)")
        }
        // Second request while pending: machine ignores it AND the harness slot
        // must survive untouched.
        model.switchTo("cx-b")
        XCTAssertEqual(model.switchHarness, .claude, "mid-pending request must not clobber the harness")
        guard case .pending("cl-b") = model.switchPhase else {
            return XCTFail("pending switch must survive, got \(model.switchPhase)")
        }
        // The original claude switch still confirms off the claude slot.
        model.dispatch(.observedActive("cl-b"))
        guard case .confirmed = model.switchPhase else {
            return XCTFail("original switch must still confirm, got \(model.switchPhase)")
        }
        model.dismissSwitch()
    }

    @MainActor
    func testInspectedFallsBackToCodexChainHeadWhenNoActiveCodex() throws {
        // The codex twin of PanelLogicTests' claude chain-head fallback: on the
        // Codex tab with NO active codex slot, the detail card must default to the
        // codex chain head — never a claude profile the page doesn't list.
        let s = try JSONDecoder().decode(DaemonStatus.self, from: Data("""
        {"schema":1,"generated_at":"2099-01-01T00:00:00+00:00","active_profile":"cl-a",
         "wrap_off":false,"refresh_interval_ms":90000,"fallback_chain":["cl-a"],
         "active_codex_profile":null,"codex_fallback_chain":["cx-b","cx-a"],
         "profiles":[
           {"name":"cl-a","active":true,"windows":[]},
           {"name":"cx-a","active":false,"provider":"openai","harness":"codex","windows":[]},
           {"name":"cx-b","active":false,"provider":"openai","harness":"codex","windows":[]}
         ]}
        """.utf8))
        let model = StatusModel(preview: s, tab: .codex)
        XCTAssertEqual(model.inspected?.name, "cx-b", "falls to the CODEX chain head")
    }

    @MainActor
    func testTabChangeDismissesInlineEditorsAndConfirms() throws {
        // Review LOW: a codex add banner / removal prompt floating over the Claude
        // page answers a question the visible page no longer asks.
        let model = StatusModel(preview: try twoHarnessStatus(), tab: .codex)
        model.beginAddAccount(.codex)
        model.renaming = "cx-a"
        model.pendingRemoval = "cx-a"
        model.thresholdEdit = .fiveHour("cx-a")
        model.tab = .claude
        XCTAssertNil(model.addingHarness)
        XCTAssertNil(model.renaming)
        XCTAssertNil(model.pendingRemoval)
        XCTAssertNil(model.thresholdEdit)
    }

    // MARK: - Removal confirm is harness-scoped

    func testRemovalConsequenceScopesOtherArmedToTheSameHarness() throws {
        // Both harnesses have their sole armed member (claude cl-a, codex cx-a).
        // Removing cx-a stops CODEX auto-switch — the claude armed member does
        // nothing for the codex chain, so the copy must say "disables", not
        // "continues on the others".
        let s = try twoHarnessStatus()
        XCTAssertEqual(ChainEdit.removalConsequence(of: "cx-a", in: s), .disablesAutoSwitch)
        XCTAssertEqual(ChainEdit.removalConsequence(of: "cl-a", in: s), .disablesAutoSwitch)
        // Unarmed members still remove freely.
        XCTAssertNil(ChainEdit.removalConsequence(of: "cx-b", in: s))
    }

    // MARK: - Login banner copy (pure)

    func testLoginFlightBannerCopyIsModeAware() {
        XCTAssertEqual(LoginFlight(name: "cx", mode: .capture).bannerText,
                       "Capturing current codex login into cx…")
        XCTAssertEqual(LoginFlight(name: "a", mode: .browser).bannerText,
                       "Signing in to a — finish in your browser…")
    }

    // MARK: - Reserved names (client mirror of clauth validate_profile_name)

    func testReservedNamesAreRejectedCaseInsensitively() {
        XCTAssertNotNil(AddAccountValidation.error("daemon", existing: []))
        XCTAssertNotNil(AddAccountValidation.error("Proxy", existing: []))
        XCTAssertNotNil(AddAccountValidation.error("MCP", existing: []))
        XCTAssertNil(AddAccountValidation.error("daemon2", existing: []))
    }

    // MARK: - Chain-union membership (the settle-predicate seam)

    func testInAnyChainSpansBothHarnessChains() throws {
        let s = try twoHarnessStatus()
        XCTAssertTrue(s.inAnyChain("cl-b"))
        XCTAssertTrue(s.inAnyChain("cx-b"))
        XCTAssertFalse(s.inAnyChain("nobody"))
    }

    // MARK: - Codex strip rate-limit mapping (two-window signal)

    func testCodexRateLimitLineMapsBothWindows() throws {
        let s = try twoHarnessStatus(codexLimited: "primary")
        let cxa = try XCTUnwrap(s.profiles.first { $0.name == "cx-a" })
        let primary = try XCTUnwrap(CodexStrip.rateLimitLine(cxa))
        XCTAssertEqual(primary.message, "cx-a hit its 5h window")
        XCTAssertEqual(primary.resetsAt, "2099-01-01T05:00:00+00:00")

        let s2 = try twoHarnessStatus(codexLimited: "secondary")
        let cxa2 = try XCTUnwrap(s2.profiles.first { $0.name == "cx-a" })
        let secondary = try XCTUnwrap(CodexStrip.rateLimitLine(cxa2))
        XCTAssertEqual(secondary.message, "cx-a hit its weekly window")
        XCTAssertEqual(secondary.resetsAt, "2099-01-06T00:00:00+00:00")

        // Unknown future verdicts degrade to a generic line, never hide.
        let s3 = try twoHarnessStatus(codexLimited: "tertiary")
        let cxa3 = try XCTUnwrap(s3.profiles.first { $0.name == "cx-a" })
        XCTAssertEqual(CodexStrip.rateLimitLine(cxa3)?.message, "cx-a is rate-limited")

        // Not limited → nil (the strip shows the active line instead).
        let s4 = try twoHarnessStatus()
        let cxa4 = try XCTUnwrap(s4.profiles.first { $0.name == "cx-a" })
        XCTAssertNil(CodexStrip.rateLimitLine(cxa4))
    }

    func testCodexRateLimitLineClearsWhenTheNamedWindowLapses() throws {
        // The daemon contract: codex_rate_limit_reached is a STICKY cached verdict;
        // readers cross-check the named window's resets_at — a lapsed window clears
        // the badge (the daemon's own codex_limiter_blocked does exactly this). The
        // fixture's windows reset in 2099; a `now` past that means the account
        // recovered even though the raw field still says "primary".
        let farFuture = Date(timeIntervalSince1970: 4_500_000_000) // ~2112
        let s = try twoHarnessStatus(codexLimited: "primary")
        let cxa = try XCTUnwrap(s.profiles.first { $0.name == "cx-a" })
        XCTAssertNotNil(CodexStrip.rateLimitLine(cxa), "live window → card shows")
        XCTAssertNil(CodexStrip.rateLimitLine(cxa, now: farFuture),
                     "lapsed window → the badge clears, matching the daemon's verdict")
        // The unrecognized degrade obeys the same gate (either window live).
        let s2 = try twoHarnessStatus(codexLimited: "tertiary")
        let cxa2 = try XCTUnwrap(s2.profiles.first { $0.name == "cx-a" })
        XCTAssertNil(CodexStrip.rateLimitLine(cxa2, now: farFuture))
    }
}
