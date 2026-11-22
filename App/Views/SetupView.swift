import SwiftUI
import AppKit
import WidgetKit

// MARK: - Window

/// The first-launch setup assistant. Shown once on a fresh install (never after an update) and
/// again on demand from Settings › General.
@MainActor
enum SetupAssistant {
    static let completedKey = "didCompleteSetup"
    static let loginItemKey = "didConfigureLoginItem"

    private static var window: NSWindow?
    private static let windowDelegate = WindowDelegate()

    static var isComplete: Bool { UserDefaults.standard.bool(forKey: completedKey) }

    /// True on the very first launch only. Installs from before the setup assistant existed always
    /// set `didConfigureLoginItem` on launch, so they count as set up and updating never shows it.
    static func needsSetup() -> Bool {
        let d = UserDefaults.standard
        if d.bool(forKey: completedKey) { return false }
        if d.object(forKey: loginItemKey) != nil {
            d.set(true, forKey: completedKey)
            return false
        }
        return true
    }

    static func show() {
        if let window {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingView(rootView: SetupView(onFinish: { finish() }).environment(AppModel.shared))
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Welcome to Hangtime"
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.delegate = windowDelegate
        w.center()
        window = w
        // A Dock icon while setting up, so the window can't get lost behind others.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    static func finish() {
        window?.close()
    }

    /// Runs however the window goes away: finishing, or closing it early (which keeps the defaults).
    fileprivate static func didClose() {
        let d = UserDefaults.standard
        if d.object(forKey: loginItemKey) == nil {
            d.set(true, forKey: loginItemKey)
            AppModel.shared.setLaunchAtLogin(true)
        }
        d.set(true, forKey: completedKey)
        window = nil
        NSApp.setActivationPolicy(.accessory)
        Task { await AppModel.shared.reloadHistory() }
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            Task { @MainActor in SetupAssistant.didClose() }
        }
    }
}

// MARK: - Steps

enum SetupStep: Int, CaseIterable, Identifiable {
    case welcome, providers, accounts, t3, preferences, widgets, done
    var id: Int { rawValue }
    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }
}

struct SetupView: View {
    static let size = CGSize(width: 760, height: 580)

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onFinish: () -> Void = {}
    @State var step: SetupStep = .welcome
    @State private var forward = true

    var body: some View {
        ZStack {
            SetupBackground()
            VStack(spacing: 0) {
                ZStack {
                    page
                        .id(step)
                        .transition(reduceMotion ? .opacity : .page(forward: forward))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if step != .welcome {
                    footer
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // Loading another app's icon is slow; do it in the background long before the T3 Code page.
        .onAppear { T3Icon.shared.load() }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: WelcomePage { go(to: .providers) }
        case .providers: ProvidersPage()
        case .accounts: AccountsPage()
        case .t3: T3Page()
        case .preferences: PreferencesPage()
        case .widgets: WidgetsPage()
        case .done: DonePage()
        }
    }

    private func go(to target: SetupStep) {
        // Set the direction first, so the outgoing page already carries the matching transition.
        forward = target.rawValue > step.rawValue
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.5)) { step = target }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                if let p = step.previous { go(to: p) }
            } label: {
                Label("Back", systemImage: "chevron.left").labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .frame(width: 180, alignment: .leading)

            Spacer()
            StepDots(current: step)
            Spacer()

            HStack {
                Spacer(minLength: 0)
                primaryButton
            }
            .frame(width: 180)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .t3 where t3Skippable:
            Button("Not Now") {
                // An explicit "no": don't connect in the background later.
                UserDefaults.standard.set(true, forKey: "t3AccessRevoked")
                go(to: .preferences)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        case .done:
            Button("Start Using Hangtime", action: onFinish)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { if let n = step.next { go(to: n) } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var t3Skippable: Bool {
        switch model.t3Access {
        case .granted, .notInstalled, .unknown: false
        default: true
        }
    }
}

private struct StepDots: View {
    var current: SetupStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases.dropFirst()) { s in
                Capsule()
                    .fill(s == current ? AnyShapeStyle(Color.accentColor) :
                          AnyShapeStyle(s.rawValue < current.rawValue ? Color.primary.opacity(0.35) : Color.primary.opacity(0.14)))
                    .frame(width: s == current ? 22 : 7, height: 7)
            }
        }
        .animation(.spring(duration: 0.45, bounce: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue) of \(SetupStep.allCases.count - 1)")
    }
}

// MARK: - Shared building blocks

private struct PageSlide: ViewModifier {
    var x: CGFloat
    var opacity: Double
    var blur: CGFloat
    func body(content: Content) -> some View {
        content.offset(x: x).opacity(opacity).blur(radius: blur)
    }
}

private extension AnyTransition {
    static func page(forward: Bool) -> AnyTransition {
        let d: CGFloat = forward ? 1 : -1
        return .asymmetric(
            insertion: .modifier(active: PageSlide(x: 70 * d, opacity: 0, blur: 8), identity: PageSlide(x: 0, opacity: 1, blur: 0)),
            removal: .modifier(active: PageSlide(x: -70 * d, opacity: 0, blur: 8), identity: PageSlide(x: 0, opacity: 1, blur: 0)))
    }
}

/// Fades and lifts content in on appear, staggered by `index`.
private struct StaggerIn: ViewModifier {
    var index: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                withAnimation(.smooth(duration: 0.55).delay(0.12 + Double(index) * 0.07)) { shown = true }
            }
    }
}

private extension View {
    func staggerIn(_ index: Int) -> some View { modifier(StaggerIn(index: index)) }

    func setupCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
    }
}

private struct PageHeader: View {
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: tint.opacity(0.35), radius: 10, y: 4)
                .staggerIn(0)
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .staggerIn(1)
            Text(subtitle)
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
                .fixedSize(horizontal: false, vertical: true)
                .staggerIn(2)
        }
    }
}

private struct SetupPage<Content: View>: View {
    var symbol: String
    var tint: Color
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 22) {
            PageHeader(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
            content
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 56)
        .padding(.top, 40)
    }
}

/// Slowly drifting wash of the provider colors behind everything.
private struct SetupBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { ctx in
            let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate / 6
            MeshGradient(width: 3, height: 3, points: [
                [0, 0], [0.5 + 0.12 * Float(sin(t)), 0], [1, 0],
                [0, 0.5 + 0.15 * Float(cos(t * 0.8))], [0.5 + 0.15 * Float(sin(t * 1.3)), 0.5 + 0.12 * Float(cos(t))], [1, 0.5 + 0.15 * Float(sin(t * 0.9))],
                [0, 1], [0.5 + 0.12 * Float(cos(t * 1.1)), 1], [1, 1],
            ], colors: [
                ProviderID.claude.tint, .purple, ProviderID.codex.tint,
                .pink, Color(nsColor: .windowBackgroundColor), ProviderID.antigravity.tint,
                .indigo, .teal, ProviderID.claude.tint,
            ])
        }
        .opacity(scheme == .dark ? 0.2 : 0.22)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }
}

// MARK: - Welcome

private struct WelcomePage: View {
    var onStart: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var floating = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: AppIconImage.large)
                .resizable()
                .frame(width: 136, height: 136)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
                .offset(y: floating ? -5 : 3)
                .padding(.bottom, 22)
            Text("Welcome to Hangtime")
                .font(.system(size: 36, weight: .bold))
                .staggerIn(2)
            Text("Your Claude Code, Codex, Grok and Antigravity limits,\nalways one glance away in the menu bar.")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 8)
                .staggerIn(3)
            HeroRings()
                .padding(.top, 30)
                .staggerIn(4)
            Spacer()
            Button(action: onStart) {
                Text("Get Started")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
            .staggerIn(5)
            Text("Takes about a minute. You can change everything later in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
                .padding(.bottom, 34)
                .staggerIn(6)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.spring(duration: 0.8, bounce: 0.35)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true).delay(0.8)) { floating = true }
        }
    }
}

/// Four rings filling up, one per provider.
private struct HeroRings: View {
    private let values: [(ProviderID, Double)] = [(.claude, 0.72), (.codex, 0.9), (.grok, 0.45), (.antigravity, 0.63)]
    @State private var filled = false

    var body: some View {
        HStack(spacing: 22) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, item in
                ZStack {
                    Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: filled ? item.1 : 0)
                        .stroke(item.0.tint.gradient, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.smooth(duration: 1.4).delay(0.5 + Double(i) * 0.12), value: filled)
                    ProviderGlyph(item.0, size: 20)
                }
                .frame(width: 50, height: 50)
            }
        }
        .onAppear { filled = true }
    }
}

// MARK: - Providers

private struct ProvidersPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SetupPage(symbol: "terminal.fill", tint: .indigo, title: "Your coding tools",
                  subtitle: "Hangtime looks for the command-line tools on your Mac. Turn off the ones you don't want to track, or point it at a custom command.") {
            VStack(spacing: 0) {
                ForEach(Array(model.settings.order.enumerated()), id: \.element) { i, p in
                    if i > 0 { Divider().padding(.leading, 62) }
                    ProviderSetupRow(provider: p)
                }
            }
            .setupCard()
            .staggerIn(3)
            Text("Installed somewhere unusual or behind a wrapper? Click \(Image(systemName: "terminal")) to use your own command.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .staggerIn(4)
        }
        .task { await model.detectCLIs(force: true) }
    }
}

private struct ProviderSetupRow: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    @State private var editing = false
    @State private var draft = ""
    @State private var checking = false
    @FocusState private var focused: Bool

    var body: some View {
        let s = model.settings
        let state = model.install[provider]
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProviderGlyph(provider, size: 22)
                    .frame(width: 36, height: 36)
                    .background(provider.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName).font(.system(size: 13.5, weight: .semibold))
                    status(state)
                        .font(.caption)
                        .contentTransition(.opacity)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { editing.toggle() }
                    if editing { focused = true }
                } label: {
                    Image(systemName: "terminal")
                        .foregroundStyle(editing ? Color.accentColor : .secondary)
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Use a custom command")
                if state?.isInstalled == true {
                    Toggle("Track \(provider.displayName)", isOn: s.binding(enabled: provider))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .transition(.scale.combined(with: .opacity))
                } else if state == .missing, !editing {
                    Button("Set Command…") {
                        withAnimation(.snappy) { editing = true }
                        focused = true
                    }
                    .transition(.opacity)
                }
            }
            if editing {
                HStack(spacing: 8) {
                    TextField("Command", text: $draft, prompt: Text(provider.defaultCommand))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($focused)
                        .onSubmit(apply)
                    Button(checking ? "Checking…" : "Check", action: apply)
                        .disabled(checking)
                }
                .padding(.leading, 48)
                .transition(.opacity.combined(with: .move(edge: .top)))
                Text("Anything you'd type in a terminal: a path, an alias, or a wrapper like `npx -y @openai/codex`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 48)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(.snappy, value: state)
        .onAppear { draft = s.commands[provider] ?? provider.defaultCommand }
    }

    @ViewBuilder
    private func status(_ state: InstallState?) -> some View {
        if checking || state == nil || state == .unknown {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Looking…").foregroundStyle(.secondary)
            }
        } else if case .installed(let v)? = state {
            if model.settings.enabled[provider] ?? true {
                Label(v.map { "Found · \($0)" } ?? "Found", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else {
                Label("Found · won't be tracked", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("Not found on this Mac", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func apply() {
        let cmd = draft.trimmingCharacters(in: .whitespaces)
        model.settings.commands[provider] = cmd.isEmpty ? provider.defaultCommand : cmd
        Task {
            checking = true
            await model.detectCLIs(force: true)
            checking = false
            if model.install[provider]?.isInstalled == true {
                model.settings.enabled[provider] = true
                withAnimation(.snappy) { editing = false }
            }
        }
    }
}

// MARK: - Accounts

private struct AccountsPage: View {
    @Environment(AppModel.self) private var model
    @State private var startedAt = Date.now

    var body: some View {
        SetupPage(symbol: "person.badge.key.fill", tint: .orange, title: "Sign-in & access",
                  subtitle: "Hangtime uses the sign-in your tools already have, so there's no new account and no password to enter.") {
            if model.visibleProviders.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.title2).foregroundStyle(.secondary)
                    Text("No tools to check yet").font(.headline)
                    Text("Go back to turn one on, or install one and set it up later in Settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .setupCard()
                .staggerIn(3)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.visibleProviders.enumerated()), id: \.element) { i, p in
                        if i > 0 { Divider().padding(.leading, 62) }
                        AccountRow(provider: p, checking: isChecking(p))
                    }
                }
                .setupCard()
                .staggerIn(3)
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.yellow.gradient)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text("About Keychain access").font(.system(size: 12.5, weight: .semibold))
                    Text("Hangtime reads your tools' sign-in from the Keychain and only uses it to ask each provider for your limits. If macOS asks whether Hangtime may use a Keychain item, choose **Always Allow** so it doesn't ask again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .setupCard()
            .staggerIn(4)
        }
        .task {
            // Wait for a refresh that's already running (e.g. the one at launch), then check whatever
            // it didn't cover, such as a tool that was just turned on.
            while model.isRefreshing { try? await Task.sleep(for: .milliseconds(250)) }
            for p in model.visibleProviders where (model.snapshots[p]?.fetchedAt ?? .distantPast) < startedAt.addingTimeInterval(-120) {
                pending.insert(p)
            }
            await withTaskGroup(of: Void.self) { group in
                for p in pending { group.addTask { await model.refresh(p) } }
            }
            pending.removeAll()
        }
    }

    @State private var pending: Set<ProviderID> = []

    private func isChecking(_ p: ProviderID) -> Bool {
        pending.contains(p) || model.snapshots[p] == nil || (model.isRefreshing && model.snapshots[p]?.status != .ok)
    }
}

private struct AccountRow: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    var checking: Bool

    var body: some View {
        let snap = model.snapshots[provider]
        let signingIn = model.busy.contains("login.\(provider.rawValue)")
        HStack(spacing: 12) {
            ProviderGlyph(provider, size: 22)
                .frame(width: 36, height: 36)
                .background(provider.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName).font(.system(size: 13.5, weight: .semibold))
                Group {
                    if checking && !signingIn {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Checking your sign-in…").foregroundStyle(.secondary)
                        }
                    } else {
                        switch snap?.status {
                        case .ok?:
                            Label(signedInText(snap), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .loggedOut?:
                            Label("Signed out", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        case .error(let m)?:
                            Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        default:
                            Text("—").foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)
                .lineLimit(2)
                .contentTransition(.opacity)
            }
            Spacer()
            if signingIn {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…").font(.caption).foregroundStyle(.secondary)
            } else if !checking {
                switch snap?.status {
                case .loggedOut?:
                    Button("Sign In…") { Task { await model.login(provider) } }
                        .buttonStyle(.borderedProminent)
                case .error?:
                    Button("Try Again") { Task { await model.refresh(provider) } }
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .animation(.snappy, value: checking)
        .animation(.snappy, value: snap?.status)
    }

    private func signedInText(_ snap: ProviderSnapshot?) -> String {
        var parts = ["Signed in"]
        if let plan = Fmt.planName(snap?.plan) { parts.append(plan) }
        if let acc = snap?.account { parts.append(acc) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - T3 Code

private struct T3Page: View {
    @Environment(AppModel.self) private var model
    @State private var failed: String?

    var body: some View {
        let state = model.t3Access
        let connected: Bool = { if case .granted = state { true } else { false } }()
        let busy = model.busy.contains("t3")
        SetupPage(symbol: "chart.bar.xaxis", tint: .teal, title: "Connect T3 Code",
                  subtitle: "If you use T3 Code, Hangtime can read its usage statistics for a more complete history: every environment, priced and de-duplicated.") {
            ConnectionGraphic(connected: connected, busy: busy, available: state != .notInstalled)
                .padding(.vertical, 18)
                .staggerIn(3)

            Group {
                switch state {
                case .unknown:
                    ProgressView().controlSize(.small).frame(height: 120)
                case .notInstalled:
                    VStack(spacing: 6) {
                        Text("T3 Code isn't installed").font(.headline)
                        Text("No problem. Hangtime reads your history from the tools' local session logs instead. You can connect T3 Code later in Settings › History.")
                            .font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(nil)
                            .frame(width: 440)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .granted:
                    Text("Hangtime shows up as “Hangtime” under Sharing & access in T3 Code. Access renews on its own.")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .frame(width: 440)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                default:
                    VStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Bullet(symbol: "lock.fill", text: "Read-only: usage statistics, nothing else")
                            Bullet(symbol: "person.badge.shield.checkmark.fill", text: "Shows up as “Hangtime” under Sharing & access in T3 Code")
                            Bullet(symbol: "xmark.circle.fill", text: "Revoke any time, here in Settings or in T3 Code")
                        }
                        .padding(14)
                        .setupCard()
                        Button {
                            failed = nil
                            Task {
                                await model.grantT3Access()
                                if case .granted = model.t3Access {} else { failed = model.toast }
                            }
                        } label: {
                            Text(busy ? "Connecting…" : "Connect to T3 Code").frame(minWidth: 160)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(busy)
                        if let failed {
                            Text(failed).font(.caption).foregroundStyle(.orange)
                                .multilineTextAlignment(.center).frame(maxWidth: 460)
                        }
                    }
                }
            }
            .staggerIn(4)
            .animation(.smooth, value: state)
        }
        .task { await model.refreshT3Access() }
    }
}

private struct Bullet: View {
    var symbol: String
    var text: String
    var body: some View {
        Label {
            Text(text).font(.callout)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.teal).frame(width: 18)
        }
    }
}

/// Hangtime ⟷ T3 Code, with a marching dotted line that turns solid once connected.
private struct ConnectionGraphic: View {
    var connected: Bool
    var busy: Bool
    var available: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion


    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: AppIconImage.small).resizable().frame(width: 64, height: 64)
            // Low frame rate and its own layer: only the dots get redrawn, not the icons next to them.
            TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion || connected || !available)) { ctx in
                let phase = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate * (busy ? 40 : 14)
                ZStack {
                    Path { p in
                        p.move(to: CGPoint(x: 4, y: 15))
                        p.addLine(to: CGPoint(x: 126, y: 15))
                    }
                        .stroke(connected ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(Color.secondary.opacity(available ? 0.6 : 0.3)),
                                style: StrokeStyle(lineWidth: connected ? 3 : 2, lineCap: .round,
                                                   dash: connected ? [] : [1, 7], dashPhase: -phase))
                    Image(systemName: connected ? "checkmark.circle.fill" : (available ? "link.circle.fill" : "minus.circle.fill"))
                        .font(.system(size: 22))
                        .foregroundStyle(.white, connected ? Color.green : Color.secondary)
                        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(2))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: connected)
                }
            }
            .frame(width: 130, height: 30)
            .drawingGroup()
            Group {
                if let icon = T3Icon.shared.image {
                    Image(nsImage: icon).resizable()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary)
                        .overlay(Text("T3").font(.system(size: 22, weight: .bold, design: .rounded)).foregroundStyle(.secondary))
                        .padding(5)
                }
            }
            .frame(width: 64, height: 64)
            .opacity(available ? 1 : 0.45)
        }
        .animation(.spring(duration: 0.5, bounce: 0.3), value: connected)
    }
}

/// Hangtime’s own icon, rendered once at the sizes setup shows it. The full icon has many layers and is
/// expensive to draw, which made pages that redraw around it (the T3 Code page) stutter.
@MainActor
enum AppIconImage {
    static let large = NSApp.applicationIconImage.rasterized(points: 136)
    static let small = NSApp.applicationIconImage.rasterized(points: 64)
}

extension NSImage {
    /// A single bitmap of this image at `points` × `points` (2× for Retina).
    nonisolated func rasterized(points: CGFloat) -> NSImage {
        let px = Int(points * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return self }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let out = NSImage(size: NSSize(width: points, height: points))
        out.addRepresentation(rep)
        return out
    }
}

/// T3 Code's app icon, from whichever build the user has: the running one, else the regular
/// "T3 Code.app", else another build such as Nightly. Loaded off the main thread.
@MainActor
@Observable
final class T3Icon {
    static let shared = T3Icon()
    private(set) var image: NSImage?
    private var started = false

    func load() {
        guard !started else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            let rendered = Self.find()
            await MainActor.run { self.image = rendered }
        }
    }

    nonisolated private static func find() -> NSImage? {
        guard let url = appURL() else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path).rasterized(points: 64)
    }

    nonisolated private static func appURL() -> URL? {
        let isT3: (URL) -> Bool = { $0.lastPathComponent.hasPrefix("T3 Code") && $0.pathExtension == "app" }
        if let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleURL).first(where: isT3) {
            return running
        }
        let fm = FileManager.default
        let dirs = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let found = dirs.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }.filter(isT3)
        return found.first { $0.lastPathComponent == "T3 Code.app" } ?? found.sorted { $0.path < $1.path }.first
    }
}

// MARK: - Preferences

private struct PreferencesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        SetupPage(symbol: "slider.horizontal.3", tint: .pink, title: "Make it yours",
                  subtitle: "A few basics. Everything else, from colors to date formats, is in Settings.") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.green.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login").font(.system(size: 13.5, weight: .semibold))
                        Text("Keeps your limits in the menu bar after a restart. macOS confirms this with a notification.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(14)
                .setupCard()
                .staggerIn(3)

                VStack(alignment: .leading, spacing: 12) {
                    Text("In the menu bar").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 10) {
                        ForEach(MenuBarStyle.allCases) { style in
                            StyleChoice(style: style, selected: s.menuBarStyle == style) {
                                withAnimation(.snappy) { s.menuBarStyle = style }
                            }
                        }
                    }
                    if s.menuBarStyle == .percent || s.menuBarStyle == .perProvider {
                        Toggle(isOn: $s.menuBarShowsResetTime) {
                            Text("Show the time until reset when a limit is used up")
                                .font(.callout)
                        }
                        .toggleStyle(.checkbox)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    HStack {
                        Text("Show").font(.callout).foregroundStyle(.secondary)
                        Picker("Show", selection: $s.menuBarWindow) {
                            ForEach(MenuBarWindowChoice.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(s.menuBarStyle == .iconOnly)
                        Spacer()
                        Text("Check usage").font(.callout).foregroundStyle(.secondary)
                        Picker("Check usage", selection: $s.refreshMinutes) {
                            Text("As often as possible").tag(0.0)
                            Text("Every 5 minutes").tag(5.0)
                            Text("Every 15 minutes").tag(15.0)
                            Text("Every 30 minutes").tag(30.0)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: s.refreshMinutes) { model.scheduleTimer() }
                    }
                }
                .padding(14)
                .setupCard()
                .staggerIn(4)
            }
        }
        .onAppear {
            // Open at login is on by default; doing it here means macOS's "Login item added" notice
            // shows up while the user is looking at the switch that controls it.
            let d = UserDefaults.standard
            if d.object(forKey: SetupAssistant.loginItemKey) == nil {
                d.set(true, forKey: SetupAssistant.loginItemKey)
                model.setLaunchAtLogin(true)
            }
        }
    }
}

private struct StyleChoice: View {
    @Environment(AppModel.self) private var model
    var style: MenuBarStyle
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: MenuBarLabel.render(items: items, style: style, showReset: model.settings.menuBarShowsResetTime))
                    .renderingMode(.template)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(style.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .padding(8)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .scaleEffect(selected ? 1.0 : 0.97)
        }
        .buttonStyle(.plain)
    }

    /// The user's real providers when there are any, otherwise a sample.
    private var items: [(ProviderID, UsageWindow?, Bool)] {
        let s = model.settings
        let real = model.visibleProviders.filter { s.inMenuBar[$0] ?? true }
        if !real.isEmpty {
            return real.prefix(3).map { p in
                let snap = model.snapshots[p]
                return (p, snap.flatMap { s.menuBarWindow.pick(from: $0) }, false)
            }
        }
        let sample = SharedState.placeholder
        return sample.visibleProviders.map { p in (p, sample.snapshot(for: p).flatMap { s.menuBarWindow.pick(from: $0) }, false) }
    }
}

// MARK: - Widgets

private struct WidgetsPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fanned = false
    @State private var bob = false

    private var state: SharedState {
        let snaps = model.visibleSnapshots.filter { !$0.windows.isEmpty }
        guard !snaps.isEmpty else { return .placeholder }
        return SharedState(providers: Array(model.snapshots.values), history: model.history,
                           visibleProviders: snaps.map(\.provider))
    }

    var body: some View {
        let entry = UsageEntry(date: .now, state: state, intent: nil)
        SetupPage(symbol: "square.grid.2x2.fill", tint: .blue, title: "Add widgets",
                  subtitle: "Put your limits on the desktop or in Notification Center. They update on their own whenever Hangtime checks.") {
            HStack(alignment: .center, spacing: 34) {
                ZStack {
                    widget(AnyView(SingleGaugeView(entry: entry, config: SingleGaugeIntent())), size: .init(width: 170, height: 170))
                        .scaleEffect(0.62)
                        .rotationEffect(.degrees(fanned ? -9 : 0))
                        .offset(x: fanned ? -92 : 0, y: fanned ? -40 + (bob ? -3 : 3) : 0)
                    widget(AnyView(HeatmapWidgetView(entry: entry, config: HeatmapIntent(), familyOverride: .systemSmall)), size: .init(width: 170, height: 170))
                        .scaleEffect(0.62)
                        .rotationEffect(.degrees(fanned ? 8 : 0))
                        .offset(x: fanned ? 96 : 0, y: fanned ? -34 + (bob ? 3 : -3) : 0)
                    widget(AnyView(OverviewView(entry: entry, config: OverviewIntent(), familyOverride: .systemMedium)), size: .init(width: 364, height: 170))
                        .scaleEffect(0.7)
                        .offset(y: fanned ? 46 + (bob ? -2 : 2) : 0)
                }
                .frame(width: 300, height: 250)
                .staggerIn(3)

                VStack(alignment: .leading, spacing: 14) {
                    StepRow(n: 1, text: "Right-click an empty spot on your desktop and choose **Edit Widgets…**")
                    StepRow(n: 2, text: "Search for **Hangtime**.")
                    StepRow(n: 3, text: "Drag a widget onto the desktop or into Notification Center. Right-click it and choose **Edit** to pick a provider or limit.")
                    Divider()
                    Label {
                        Text("There's also a **Usage Limit** control for Control Center and the menu bar.")
                            .font(.caption).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "switch.2").foregroundStyle(.blue)
                    }
                }
                .frame(maxWidth: 290, alignment: .leading)
                .staggerIn(4)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.3).delay(0.25)) { fanned = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true).delay(1.1)) { bob = true }
        }
    }

    private func widget(_ view: AnyView, size: CGSize) -> some View {
        view
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 8)
            .allowsHitTesting(false)
    }
}

private struct StepRow: View {
    var n: Int
    var text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue.gradient))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Done

private struct DonePage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(Color.green.opacity(appeared ? 0 : 0.5), lineWidth: 2)
                    .frame(width: 96, height: 96)
                    .scaleEffect(appeared ? 1.7 : 0.8)
                Circle()
                    .fill(Color.green.gradient)
                    .frame(width: 88, height: 88)
                    .shadow(color: .green.opacity(0.35), radius: 16, y: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: appeared)
            }
            .scaleEffect(appeared ? 1 : 0.4)
            .opacity(appeared ? 1 : 0)
            Text("You're all set")
                .font(.system(size: 32, weight: .bold))
                .padding(.top, 26)
                .staggerIn(2)
            Text("Hangtime lives in your menu bar. Click it any time to see what's left.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
                .staggerIn(3)

            MenuBarMock(pulse: pulse)
                .padding(.top, 26)
                .staggerIn(4)

            VStack(alignment: .leading, spacing: 10) {
                Tip(symbol: "bell.badge", tint: .red,
                    text: "Alerts are off for now. Turn on reset and low-limit alerts in **Settings › Notifications**, and macOS will ask for permission then.")
                Tip(symbol: "gearshape", tint: .gray,
                    text: "Everything else is in **Settings** (⌘,), including this setup, if you want to run it again.")
            }
            .frame(maxWidth: 480)
            .padding(.top, 26)
            .staggerIn(5)
            Spacer()
        }
        .padding(.horizontal, 56)
        .onAppear {
            withAnimation(.spring(duration: 0.7, bounce: 0.45).delay(0.1)) { appeared = true }
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true).delay(1)) { pulse = true }
        }
    }
}

/// A slice of a menu bar with the real Hangtime item, softly highlighted.
private struct MenuBarMock: View {
    @Environment(AppModel.self) private var model
    var pulse: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            MenuBarLabel()
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(pulse ? 0.28 : 0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.accentColor.opacity(pulse ? 0.8 : 0.3), lineWidth: 1.5))
            Image(systemName: "switch.2")
            Text(Date.now, format: .dateTime.weekday(.abbreviated).hour().minute())
                .font(.system(size: 12, weight: .medium))
        }
        .font(.system(size: 13))
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
    }
}

private struct Tip: View {
    var symbol: String
    var tint: Color
    var text: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
