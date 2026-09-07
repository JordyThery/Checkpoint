import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ABMSettingsTab()
                .tabItem { Label("Apple Business", systemImage: "apple.logo") }
            JamfSettingsTab()
                .tabItem { Label("Jamf Pro", systemImage: "server.rack") }
        }
        .frame(width: 580, height: 500)
    }
}

// MARK: - Apple Business Manager

struct ABMSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var clientID = ""
    @State private var keyID = ""
    @State private var privateKeyPEM = ""
    @State private var hasStoredKey = false
    @State private var showingImporter = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("API Credentials") {
                TextField("Client ID", text: $clientID, prompt: Text("BUSINESSAPI.xxxxxxxx-…"))
                TextField("Key ID", text: $keyID)
            }
            Section("Private Key") {
                if hasStoredKey {
                    LabeledContent("Stored Key", value: "A private key is saved in your keychain")
                }
                TextEditor(text: $privateKeyPEM)
                    .font(.caption.monospaced())
                    .frame(height: 90)
                Button("Import .pem File…") { showingImporter = true }
                Text("Paste the PEM private key downloaded when creating the API key in Apple Business Manager (Preferences → API), or import the .pem file. The key is stored only in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Save") { save() }
                    Button("Test Connection") { test() }
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let statusMessage {
                    Text(statusMessage).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                let hasAccess = url.startAccessingSecurityScopedResource()
                defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                if let contents = try? String(contentsOf: url, encoding: .utf8) {
                    privateKeyPEM = contents
                }
            }
        }
        .onAppear {
            clientID = settings.abm.clientID
            keyID = settings.abm.keyID
            hasStoredKey = Keychain.get(ABMConfig.privateKeyKeychainKey) != nil
        }
    }

    private func save() {
        settings.abm.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.abm.keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pem.isEmpty {
            Keychain.set(pem, for: ABMConfig.privateKeyKeychainKey)
            hasStoredKey = true
            privateKeyPEM = ""
        }
        statusMessage = "Saved."
    }

    private func test() {
        save()
        guard let pem = Keychain.get(ABMConfig.privateKeyKeychainKey), !pem.isEmpty else {
            statusMessage = "Add the private key first."
            return
        }
        let client = ABMClient(clientID: clientID, keyID: keyID, privateKeyPEM: pem)
        isTesting = true
        Task {
            do {
                let count = try await client.verify()
                statusMessage = "Connected — \(count) MDM server\(count == 1 ? "" : "s") visible."
            } catch {
                statusMessage = error.localizedDescription
            }
            isTesting = false
        }
    }
}

// MARK: - Jamf Pro

struct JamfSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(settings.jamfServers) { server in
                        Text(server.displayName).tag(server.id)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add a Jamf Pro server")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        .help("Remove the selected server")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let index = settings.jamfServers.firstIndex(where: { $0.id == selectedID }) {
                JamfServerEditor(config: settings.jamfServers[index])
                    .id(settings.jamfServers[index].id)
            } else {
                ContentUnavailableView(
                    "No Server Selected",
                    systemImage: "server.rack",
                    description: Text("Add a Jamf Pro server with the + button. You can store several, e.g. production and testing.")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedID = settings.jamfServers.first?.id }
    }

    private func add() {
        let server = JamfServerConfig(name: "New Server")
        settings.jamfServers.append(server)
        selectedID = server.id
    }

    private func removeSelected() {
        guard let selectedID,
              let index = settings.jamfServers.firstIndex(where: { $0.id == selectedID }) else { return }
        Keychain.delete(settings.jamfServers[index].secretKeychainKey)
        settings.jamfServers.remove(at: index)
        self.selectedID = settings.jamfServers.first?.id
    }
}

struct JamfServerEditor: View {
    @Environment(AppSettings.self) private var settings
    let config: JamfServerConfig

    @State private var name = ""
    @State private var baseURL = ""
    @State private var authMethod: JamfAuthMethod = .apiClient
    @State private var account = ""
    @State private var secret = ""
    @State private var hasStoredSecret = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name, prompt: Text("Production"))
                TextField("URL", text: $baseURL, prompt: Text("https://yourorg.jamfcloud.com"))
            }
            Section("Authentication") {
                Picker("Method", selection: $authMethod) {
                    ForEach(JamfAuthMethod.allCases) { method in
                        Text(method.label).tag(method)
                    }
                }
                TextField(authMethod == .apiClient ? "Client ID" : "Username", text: $account)
                SecureField(
                    authMethod == .apiClient ? "Client Secret" : "Password",
                    text: $secret,
                    prompt: hasStoredSecret ? Text("Stored in keychain — type to replace") : nil
                )
            }
            Section {
                HStack {
                    Button("Save") { save() }
                    Button("Test Connection") { test() }
                        .disabled(isTesting)
                    if isTesting {
                        ProgressView().controlSize(.small)
                    }
                }
                if let statusMessage {
                    Text(statusMessage).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            name = config.name
            baseURL = config.baseURL
            authMethod = config.authMethod
            account = config.account
            hasStoredSecret = Keychain.get(config.secretKeychainKey) != nil
        }
    }

    private func save() {
        guard let index = settings.jamfServers.firstIndex(where: { $0.id == config.id }) else { return }
        settings.jamfServers[index].name = name
        settings.jamfServers[index].baseURL = baseURL
        settings.jamfServers[index].authMethod = authMethod
        settings.jamfServers[index].account = account
        if !secret.isEmpty {
            Keychain.set(secret, for: config.secretKeychainKey)
            hasStoredSecret = true
            secret = ""
        }
        statusMessage = "Saved."
    }

    private func test() {
        save()
        guard let effectiveSecret = Keychain.get(config.secretKeychainKey), !effectiveSecret.isEmpty else {
            statusMessage = "Enter the credentials first."
            return
        }
        var current = config
        current.name = name
        current.baseURL = baseURL
        current.authMethod = authMethod
        current.account = account
        guard let client = JamfClient(config: current, secret: effectiveSecret) else {
            statusMessage = "Enter a valid server URL first."
            return
        }
        isTesting = true
        Task {
            do {
                try await client.verify()
                statusMessage = "Connected successfully."
            } catch {
                statusMessage = error.localizedDescription
            }
            isTesting = false
        }
    }
}
