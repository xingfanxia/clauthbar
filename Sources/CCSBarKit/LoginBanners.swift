import SwiftUI

/// The panel-top inline editors and the login-in-flight banner (TABS-1: moved out
/// of PanelView, which is now the tab router). All three float at the panel top —
/// a TextField needs a stable focus home, and an in-flight login must be visible
/// no matter which page or detail card is showing.

// MARK: - Login-in-flight banner (AUTH-3, mode-aware since TABS-1)

/// A login is running. The copy is MODE-aware: a browser flow sends the user to go
/// finish a sign-in; a codex capture is an instant local copy — telling the user to
/// "finish in your browser" for a flow that never opened one reads as a hang.
struct LoginFlightBanner: View {
    let flight: LoginFlight

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(flight.bannerText)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.sapphire.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
    }
}

// MARK: - Rename banner

/// The inline profile-rename editor: a TextField pre-filled with the current name,
/// live client-side validation (mirroring the daemon's rule), and Rename/Cancel.
/// Its own `@State` for the field + `@FocusState` so typing lands here on open.
struct RenameBanner: View {
    @ObservedObject var model: StatusModel
    let name: String
    @State private var newName: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Rename \(name)").font(.subheadline).fontWeight(.medium)
            HStack(spacing: 6) {
                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(commit)
                Button("Cancel") { model.cancelRename() }.controlSize(.small)
                Button("Rename", action: commit).controlSize(.small)
                    .tint(Theme.accent)
                    .disabled(liveError != nil)
                    .keyboardShortcut(.return, modifiers: [])
            }
            if let err = liveError, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(err).font(.caption).foregroundStyle(Theme.danger)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onAppear {
            newName = name
            focused = true
        }
    }

    /// Live validation echoing the daemon's rule (nil ⇒ valid).
    private var liveError: String? {
        StatusModel.renameValidationError(newName, old: name, existing: model.listProfiles.map(\.name))
    }

    private func commit() {
        guard liveError == nil else { return }
        model.commitRename(name, to: newName)
    }
}

// MARK: - Add-account banner

/// The inline add-account editor: a name TextField, live client-side validation
/// (mirroring clauth's `validate_profile_name` via `AddAccountValidation`, incl. the
/// case-insensitive collision pre-block), and the harness's sign-in verbs. Claude
/// offers the browser OAuth flow; codex offers BOTH doors — capture the login codex
/// already holds (instant, `--codex`) or a fresh browser PKCE sign-in
/// (`--codex --browser`). Own `@State` + `@FocusState` so typing lands here on open.
struct AddAccountBanner: View {
    @ObservedObject var model: StatusModel
    let harness: Harness
    @State private var name: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(harness == .codex ? "Add codex account" : "Add account")
                .font(.subheadline).fontWeight(.medium)
            if harness == .codex {
                // TWO rows for codex: the name field + three buttons cannot share
                // one 340pt row without truncating the PRIMARY verb ("Capture
                // cu…" — observed live). Field gets its own line; verbs below.
                TextField("new profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    // ⏎ takes the PRIMARY door: capture (the common case — codex
                    // is already signed in on this machine).
                    .onSubmit { commit(.capture) }
                HStack(spacing: 6) {
                    Button("Cancel") { model.cancelAddAccount() }.controlSize(.small)
                    Spacer(minLength: 4)
                    Button("Capture current login") { commit(.capture) }
                        .controlSize(.small).tint(Theme.accent)
                        .disabled(commitDisabled)
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Copies the login codex is signed in with right now — instant, no browser.")
                    Button("Sign in…") { commit(.browser) }
                        .controlSize(.small)
                        .disabled(commitDisabled)
                        .help("Opens your browser for a fresh codex sign-in.")
                }
            } else {
                HStack(spacing: 6) {
                    TextField("new profile name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit { commit(.browser) }
                    Button("Cancel") { model.cancelAddAccount() }.controlSize(.small)
                    Button("Sign in…") { commit(.browser) }
                        .controlSize(.small).tint(Theme.accent)
                        // Also disabled while ANY login runs (the single-login
                        // guard) — an enabled button whose submit silently no-ops
                        // reads as broken.
                        .disabled(commitDisabled)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            // Show the exact rejection reason once the user has typed something; before
            // that, a neutral hint about what the verbs will do.
            if let err = liveError, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(err).font(.caption).foregroundStyle(Theme.danger)
            } else {
                Text(harness == .codex
                     ? "Capture copies the login codex already has; Sign in opens your browser. Either creates the profile."
                     : "Opens your browser to sign in; creates the profile on success.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onAppear { focused = true }
    }

    private var commitDisabled: Bool { liveError != nil || model.loginInFlight != nil }

    /// Live validation echoing clauth's rule (nil ⇒ valid). Names are global
    /// across harnesses, so the collision check spans the full profile list.
    private var liveError: String? {
        AddAccountValidation.error(name, existing: model.listProfiles.map(\.name))
    }

    private func commit(_ mode: LoginMode) {
        guard liveError == nil, model.loginInFlight == nil else { return }
        model.addAccount(name, codex: harness == .codex, mode: mode)
    }
}
