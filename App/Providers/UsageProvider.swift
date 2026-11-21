import Foundation

protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    /// Reads the current limits. Must never throw — failures are reported via `status`.
    func fetch(command: String) async -> ProviderSnapshot
    /// Redeems a banked reset (nil = let the backend pick the next one). Returns a user facing message.
    func redeem(reset: BankedReset?, command: String) async throws -> String
    /// Starts the CLI's sign-in flow without a terminal and returns once it finished.
    func login(command: String) async throws
    func cliVersion(command: String) async -> String?
}

enum Providers {
    static let all: [ProviderID: any UsageProvider] = [
        .claude: ClaudeProvider(),
        .codex: CodexProvider(),
        .grok: GrokProvider(),
        .antigravity: AntigravityProvider(),
    ]
}
