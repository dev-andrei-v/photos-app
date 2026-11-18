import AuthenticationServices
import Core
import CloudCore
import SwiftUI

struct SignInView: View {
    let model: AppModel
    /// Prefilled when adding a second account or re-signing in.
    var initialEmail = ""
    var onSignedIn: (() -> Void)?

    @State private var email = ""
    @State private var password = ""
    @State private var working: Method?
    @State private var errorMessage: String?
    /// How this server lets people sign in, once it has answered.
    @State private var options: CloudSignInOptions?
    @FocusState private var focus: Field?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    private enum Field { case email, password }
    private enum Method { case password, singleSignOn }

    private var isWorking: Bool { working != nil }
    /// Until the server has answered, both ways in are offered.
    private var offersPassword: Bool { options?.password ?? true }
    /// Only once the server says it has single sign-on (no button that appears and vanishes).
    private var offersSingleSignOn: Bool { options?.singleSignOn ?? false }

    var body: some View {
        Form {
            if offersPassword {
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(signIn)
                } header: {
                    Text("Cloud account")
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Error: \(errorMessage)")
                }
            }

            if offersPassword {
                Section {
                    Button(action: signIn) {
                        HStack {
                            Text("Sign In")
                            Spacer()
                            if working == .password { ProgressView() }
                        }
                    }
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
                }
            }

            if offersSingleSignOn {
                Section {
                    Button(action: signInWithSingleSignOn) {
                        HStack {
                            Text(options?.singleSignOnTitle ?? "Sign In with Single Sign-On")
                            Spacer()
                            if working == .singleSignOn { ProgressView() }
                        }
                    }
                    .disabled(isWorking)
                } footer: {
                    Text("Signs in through your server’s identity provider (OAuth / OpenID Connect).")
                }
            }

            ServerAddressSection(model: model)
        }
        .navigationTitle("Photos")
        .onAppear {
            if email.isEmpty { email = initialEmail }
        }
        // Again whenever another address starts answering (e.g. after editing the server below).
        .task(id: model.connection.activeServer?.url) {
            let answer = await model.signInOptions()
            if !Task.isCancelled { options = answer }
        }
    }

    private func signIn() {
        guard !isWorking, !email.isEmpty, !password.isEmpty else { return }
        working = .password
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                try await model.signIn(email: email, password: password)
                password = ""
                onSignedIn?()
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }

    private func signInWithSingleSignOn() {
        guard !isWorking else { return }
        working = .singleSignOn
        errorMessage = nil
        Task {
            defer { working = nil }
            do {
                try await model.signInWithSingleSignOn { url, callbackScheme in
                    try await webAuthenticationSession.authenticate(using: url, callbackURLScheme: callbackScheme)
                }
                onSignedIn?()
            } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                // The sheet was closed: nothing to report.
            } catch {
                errorMessage = (error as? CloudError)?.message ?? error.localizedDescription
            }
        }
    }
}

/// The editable server address, with a connection test.
struct ServerAddressSection: View {
    let model: AppModel

    @State private var address = ""
    @State private var report: [String]?
    @State private var isTesting = false

    var body: some View {
        Section {
            TextField("photos.example.com", text: $address)
                .accessibilityLabel("Server address")
            Button {
                test()
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if isTesting { ProgressView() }
                }
            }
            .disabled(isTesting)
            if let report {
                ForEach(report, id: \.self) { line in
                    Text(line)
                        .font(.footnote)
                        .foregroundStyle(line.contains("OK") ? Color.secondary : Color.red)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your server’s address. A name such as photos.example.com is reached over HTTPS; add http:// and a port for a server without it.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(.URL)
        .onAppear {
            address = model.serverSettings.address?.absoluteString ?? ""
        }
        .onChange(of: address) { save() }
    }

    private func save() {
        let url = ServerAddress.normalize(address)
        guard url != model.serverSettings.address else { return }
        model.serverSettings.address = url
        model.reconnect()
    }

    private func test() {
        isTesting = true
        Task {
            report = await model.connectivityReport()
            isTesting = false
        }
    }
}
