import SwiftUI

struct LoginView: View {
    @EnvironmentObject var auth: AuthModel
    @State private var isSignUp = false
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.17, green: 0.13, blue: 0.10),
                         Color(red: 0.12, green: 0.09, blue: 0.07)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Image(systemName: "paintpalette.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                VStack(spacing: 4) {
                    Text("Coloring Book")
                        .font(.title).fontWeight(.semibold)
                    Text(isSignUp ? "Create an account"
                                  : "Log in to color with friends")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .frame(width: 280)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                }

                if let msg = auth.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(width: 280)
                }

                Button {
                    Task {
                        if isSignUp {
                            await auth.signup(username: username, password: password)
                        } else {
                            await auth.login(username: username, password: password)
                        }
                    }
                } label: {
                    HStack {
                        if auth.busy { ProgressView().controlSize(.small) }
                        Text(isSignUp ? "Create account" : "Log in")
                    }
                    .frame(width: 200)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(auth.busy || username.count < 3 || password.count < 8)

                Button {
                    isSignUp.toggle()
                    auth.errorMessage = nil
                } label: {
                    Text(isSignUp ? "Already have an account? Log in"
                                  : "No account yet? Sign up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                if isSignUp {
                    VStack(spacing: 2) {
                        Text("Username: 3–20 characters (letters / numbers / _).")
                        Text("Password: at least 8 characters.")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
            }
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 560)
    }
}
