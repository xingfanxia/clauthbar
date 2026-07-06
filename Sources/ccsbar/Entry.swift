import CCSBarKit

/// The thin executable: all logic lives in the CCSBarKit library (so a test
/// target can `@testable import` it). This is just the `@main` entry that hands
/// off to the library's `runCCSBar()`.
@main
struct CCSBarMain {
    @MainActor
    static func main() { runCCSBar() }
}
