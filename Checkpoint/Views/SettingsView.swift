import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ABMSettingsTab()
                .tabItem { Label("Apple", systemImage: "apple.logo") }
            JamfSettingsTab()
                .tabItem { Label("Jamf", systemImage: "server.rack") }
        }
        .frame(width: 580, height: 500)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { appearance in
                    Text(appearance.label).tag(appearance)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Warn when a service is not configured", isOn: Binding(
                get: { !settings.configurationHintDismissed },
                set: { settings.configurationHintDismissed = !$0 }
            ))
            .help("Show the message above the table when Apple Business, Apple School Manager or a Jamf server is missing")
        }
        .formStyle(.grouped)
    }
}

// MARK: - Apple Business

struct ABMSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(settings.abmOrgs) { org in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(org.displayName)
                            // Named here so two organizations of different
                            // services are distinguishable at a glance.
                            Text(org.kind.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(org.id)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add an Apple Business or Apple School Manager organization")
                    Button { removeSelected() } label: { Image(systemName: "minus") }
                        .disabled(selectedID == nil)
                        .help("Remove the selected organization")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 180)
            Divider()
            if let index = settings.abmOrgs.firstIndex(where: { $0.id == selectedID }) {
                ABMOrgEditor(config: settings.abmOrgs[index])
                    .id(settings.abmOrgs[index].id)
            } else {
                ContentUnavailableView(
                    "No Organization Selected",
                    systemImage: "apple.logo",
                    description: Text("Add an Apple Business or Apple School Manager organization with the + button. You can store several and switch between them in the toolbar.")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedID = settings.abmOrgs.first?.id }
    }

    private func add() {
        let org = ABMConfig(name: "New Organization")
        settings.abmOrgs.append(org)
        selectedID = org.id
    }

    private func removeSelected() {
        guard let selectedID,
              let index = settings.abmOrgs.firstIndex(where: { $0.id == selectedID }) else { return }
        Keychain.delete(settings.abmOrgs[index].privateKeyKeychainKey)
        settings.abmOrgs.remove(at: index)
        self.selectedID = settings.abmOrgs.first?.id
    }
}

struct ABMOrgEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ActivityLog.self) private var log
    let config: ABMConfig

    @State private var name = ""
    @State private var kind: AppleOrgKind = .business
    @State private var clientID = ""
    @State private var keyID = ""
    @State private var privateKeyPEM = ""
    @State private var hasStoredKey = false
    @State private var showingImporter = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("Organization") {
                TextField("Name", text: $name, prompt: Text("Head Office"))
                Picker("Service", selection: $kind) {
                    ForEach(AppleOrgKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                if !kind.supportsRelease {
                    Text("\(kind.label) uses the same API as Apple Business, except that it provides no way to release devices from the organization. That action is dimmed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("API Credentials") {
                TextField("Client ID", text: $clientID,
                          prompt: Text(kind == .business ? "BUSINESSAPI.xxxxxxxx-…" : "SCHOOLAPI.xxxxxxxx-…"))
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
                Text("Paste the PEM private key downloaded when creating the API account in \(kind.label) (Settings → Integrations → API), or import the .pem file. The account needs the Device Enrollment Manager role or higher. The key is stored only in your keychain.")
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
            name = config.name
            kind = config.kind
            clientID = config.clientID
            keyID = config.keyID
            hasStoredKey = Keychain.get(config.privateKeyKeychainKey) != nil
        }
    }

    private func save() {
        guard let index = settings.abmOrgs.firstIndex(where: { $0.id == config.id }) else { return }
        settings.abmOrgs[index].name = name
        settings.abmOrgs[index].kind = kind
        settings.abmOrgs[index].clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.abmOrgs[index].keyID = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let pem = privateKeyPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pem.isEmpty {
            Keychain.set(pem, for: config.privateKeyKeychainKey)
            hasStoredKey = true
            privateKeyPEM = ""
        }
        statusMessage = "Saved."
    }

    private func test() {
        save()
        guard let pem = Keychain.get(config.privateKeyKeychainKey), !pem.isEmpty else {
            statusMessage = "Add the private key first."
            return
        }
        let client = ABMClient(
            clientID: clientID,
            keyID: keyID,
            privateKeyPEM: pem,
            kind: kind,
            connectionName: name.isEmpty ? config.displayName : name,
            log: log
        )
        isTesting = true
        Task {
            do {
                let count = try await client.verify()
                statusMessage = "Connected. \(count) MDM server\(count == 1 ? "" : "s") visible."
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
                        .help("Add a Jamf Pro or Jamf School server")
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
                    description: Text("Add a Jamf Pro or Jamf School server with the + button. You can store several, e.g. production and testing.")
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
    @Environment(ActivityLog.self) private var log
    let config: JamfServerConfig

    @State private var name = ""
    @State private var flavor: JamfFlavor = .pro
    @State private var baseURL = ""
    @State private var authMethod: JamfAuthMethod = .apiClient
    @State private var account = ""
    @State private var secret = ""
    @State private var region: JamfRegion = .us
    @State private var environmentID = ""
    @State private var hasStoredSecret = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    /// Jamf School has no gateway, so the Platform API rows never apply to it
    /// even if a server was switched over from Jamf Pro.
    private var isGateway: Bool { flavor == .pro && authMethod == .platformGateway }
    private var isSchool: Bool { flavor == .school }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $name, prompt: Text("Production"))
                Picker("Product", selection: $flavor) {
                    ForEach(JamfFlavor.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                TextField("URL", text: $baseURL, prompt: Text("https://yourorg.jamfcloud.com"))
                if isSchool {
                    Text("Jamf School reports fewer attributes than Jamf Pro, so the columns and actions it has no source for are hidden: FileVault, MDM profile expiry, software update state, PreStage scope and the recovery secrets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if isGateway {
                    Text("Requests go to the gateway. This URL is still used to link devices to their Jamf Pro records.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Authentication") {
                if isSchool {
                    TextField("Network ID", text: $account, prompt: Text("067680"))
                    SecureField(
                        "API Key",
                        text: $secret,
                        prompt: hasStoredSecret ? Text("Stored in keychain, type to replace") : nil
                    )
                    Text("The Network ID is under Devices → Enroll Device(s). Create the API key under Organization → Settings → API, and grant it the methods you intend to use: each key carries its own list, so a missing one refuses a single feature rather than the whole connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Method", selection: $authMethod) {
                        ForEach(JamfAuthMethod.allCases) { method in
                            Text(method.label).tag(method)
                        }
                    }
                    TextField(authMethod == .usernamePassword ? "Username" : "Client ID", text: $account)
                    SecureField(
                        authMethod == .usernamePassword ? "Password" : "Client Secret",
                        text: $secret,
                        prompt: hasStoredSecret ? Text("Stored in keychain, type to replace") : nil
                    )
                }
            }
            if isGateway {
                Section("Platform API") {
                    Picker("Region", selection: $region) {
                        ForEach(JamfRegion.allCases) { region in
                            Text(region.label).tag(region)
                        }
                    }
                    TextField("Environment ID", text: $environmentID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                    Text("Requires an environment-scoped integration created in Jamf Account, not a Jamf Pro API client. Copy the environment ID from its Integration details, and pick the region it is in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Label {
                        Text("Lock, Clear Passcode and Renew MDM Profile cannot be sent over the Platform API. Everything else works, including lookups, PreStages, sites, Wipe, Restart and Shut Down.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.callout)
                }
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
            flavor = config.flavor
            baseURL = config.baseURL
            authMethod = config.authMethod
            account = config.account
            region = config.region
            environmentID = config.environmentID
            hasStoredSecret = Keychain.get(config.secretKeychainKey) != nil
        }
    }

    private func save() {
        guard let index = settings.jamfServers.firstIndex(where: { $0.id == config.id }) else { return }
        settings.jamfServers[index].name = name
        settings.jamfServers[index].flavor = flavor
        settings.jamfServers[index].baseURL = baseURL
        settings.jamfServers[index].authMethod = authMethod
        settings.jamfServers[index].account = account
        settings.jamfServers[index].region = region
        settings.jamfServers[index].environmentID = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
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
        current.flavor = flavor
        current.baseURL = baseURL
        current.authMethod = authMethod
        current.account = account
        if isSchool {
            guard let client = JamfSchoolClient(config: current, secret: effectiveSecret, log: log) else {
                statusMessage = "Enter a valid server URL, Network ID and API key first."
                return
            }
            isTesting = true
            Task {
                do {
                    let locations = try await client.verify()
                    statusMessage = "Connected successfully. \(locations) location\(locations == 1 ? "" : "s")."
                } catch {
                    statusMessage = error.localizedDescription
                }
                isTesting = false
            }
            return
        }
        guard let client = JamfClient(config: current, secret: effectiveSecret, log: log) else {
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
