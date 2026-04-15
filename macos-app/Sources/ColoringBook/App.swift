import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ColoringBookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var auth: AuthModel
    @StateObject private var session: SessionModel

    init() {
        // Production server URL is hard-coded so DMG users connect with no
        // configuration. The `SERVER` env var still overrides for local
        // development against `http://localhost:8787`.
        let productionURL = "https://api.colorbook.adisuresh.me"
        let base = URL(
            string: ProcessInfo.processInfo.environment["SERVER"]
                ?? productionURL
        ) ?? URL(string: productionURL)!
        _auth = StateObject(wrappedValue: AuthModel(base: base))
        _session = StateObject(wrappedValue: SessionModel(baseURL: base))
    }

    var body: some Scene {
        WindowGroup("Coloring Book") {
            RootView()
                .environmentObject(auth)
                .environmentObject(session)
                .frame(minWidth: 1100, minHeight: 720)
                .task { await auth.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}

/// Routes between the login screen and the main canvas based on auth state.
struct RootView: View {
    @EnvironmentObject var auth: AuthModel
    @EnvironmentObject var session: SessionModel

    var body: some View {
        Group {
            switch auth.state {
            case .unauthenticated:
                LoginView()
            case .loading:
                ZStack {
                    Color(red: 0.12, green: 0.09, blue: 0.07).ignoresSafeArea()
                    ProgressView().controlSize(.large).tint(.white)
                }
            case .authenticated(let user, let token):
                ContentView()
                    .onAppear {
                        session.configureAuth(user: user, token: token)
                    }
                    .onChange(of: auth.state) { _, newValue in
                        if case .unauthenticated = newValue {
                            session.clearAuth()
                        }
                    }
            }
        }
    }
}
