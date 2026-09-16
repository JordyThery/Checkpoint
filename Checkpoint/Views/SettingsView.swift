import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            ABMSettingsTab()
                .tabItem { Label("Apple", systemImage: "apple.logo") }
            MDMSettingsTab()
                .tabItem { Label("MDM", systemImage: "server.rack") }
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
            .help("Show the message above the table when an Apple organization or a device management connection is missing")
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

struct MDMSettingsTab: View {
    @Environment(AppSettings.self) private var settings
    @State private var selectedID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(settings.mdmConnections) { server in
                        Text(server.displayName).tag(server.id)
                    }
                }
                Divider()
                HStack(spacing: 10) {
                    Button { add() } label: { Image(systemName: "plus") }
                        .help("Add a Jamf Pro or Jamf School server, or an Intune tenant")
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
            if let index = settings.mdmConnections.firstIndex(where: { $0.id == selectedID }) {
                MDMConnectionEditor(config: settings.mdmConnections[index])
                    .id(settings.mdmConnections[index].id)
            } else {
                ContentUnavailableView(
                    "No Server Selected",
                    systemImage: "server.rack",
                    description: Text("Add a Jamf Pro or Jamf School server, or an Intune tenant, with the + button. You can store several, e.g. production and testing.")
                )
                .frame(maxWidth: .infinity)
            }
        }
        .onAppear { selectedID = settings.mdmConnections.first?.id }
    }

    private func add() {
        let server = MDMConnection(name: "New Server")
        settings.mdmConnections.append(server)
        selectedID = server.id
    }

    private func removeSelected() {
        guard let selectedID,
              let index = settings.mdmConnections.firstIndex(where: { $0.id == selectedID }) else { return }
        Keychain.delete(settings.mdmConnections[index].secretKeychainKey)
        settings.mdmConnections.remove(at: index)
        self.selectedID = settings.mdmConnections.first?.id
    }
}

struct MDMConnectionEditor: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ActivityLog.self) private var log
    let config: MDMConnection

    @State private var name = ""
    @State private var product: MDMProduct = .jamfPro
    @State private var baseURL = ""
    @State private var authMethod: MDMAuthMethod = .apiClient
    @State private var account = ""
    @State private var secret = ""
    @State private var region: JamfRegion = .us
    @State private var environmentID = ""
    @State private var tenantID = ""
    @State private var hasStoredSecret = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    /// Jamf School has no gateway, so the Platform API rows never apply to it
    /// even if a server was switched over from Jamf Pro.
    private var isGateway: Bool { product == .jamfPro && authMethod == .platformGateway }
    private var isSchool: Bool { product == .jamfSchool }
    private var isIntune: Bool { product == .intune }

    var body: some View {
        Form {
            Section(isIntune ? "Tenant" : "Server") {
                TextField("Name", text: $name, prompt: Text("Production"))
                Picker("Product", selection: $product) {
                    ForEach(MDMProduct.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                // Changing product can leave an authentication method the new
                // product does not accept, so it is corrected here rather
                // than left to fail at sign-in.
                .onChange(of: product) { _, new in
                    let allowed = MDMAuthMethod.methods(for: new)
                    if !allowed.contains(authMethod) { authMethod = allowed[0] }
                }
                if isIntune {
                    TextField("Tenant ID", text: $tenantID, prompt: Text("contoso.onmicrosoft.com"))
                    Text("Requests go to Microsoft Graph, so no URL is needed. The tenant ID can be the GUID or a verified domain name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("URL", text: $baseURL, prompt: Text("https://yourorg.jamfcloud.com"))
                }
                if isIntune {
                    Text("Intune reports one sync time rather than Jamf's four dates, and has no sites, PreStage scope, passcode state, declarative update reporting or recovery secrets, so the columns and actions for those are hidden. The enrollment profile is hidden too, because Graph reports what a device enrolled with rather than what is assigned to it. Compliance is shown instead. Deleting a record leaves the device enrolled; Remove MDM Profile retires it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
                } else if isIntune {
                    TextField("Client ID", text: $account, prompt: Text("00000000-0000-0000-0000-000000000000"))
                    SecureField(
                        "Client Secret",
                        text: $secret,
                        prompt: hasStoredSecret ? Text("Stored in keychain, type to replace") : nil
                    )
                    Text("Create an app registration in Entra, add a client secret, and grant it the application permissions under Microsoft Graph — DeviceManagementManagedDevices.Read.All to look devices up, and PrivilegedOperations.All to send commands. Application permissions need admin consent before any of them work.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Method", selection: $authMethod) {
                        ForEach(MDMAuthMethod.methods(for: product)) { method in
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
            product = config.product
            baseURL = config.baseURL
            authMethod = config.authMethod
            account = config.account
            region = config.region
            environmentID = config.environmentID
            tenantID = config.tenantID
            hasStoredSecret = Keychain.get(config.secretKeychainKey) != nil
        }
    }

    private func save() {
        guard let index = settings.mdmConnections.firstIndex(where: { $0.id == config.id }) else { return }
        settings.mdmConnections[index].name = name
        settings.mdmConnections[index].product = product
        settings.mdmConnections[index].baseURL = baseURL
        settings.mdmConnections[index].authMethod = authMethod
        settings.mdmConnections[index].account = account
        settings.mdmConnections[index].region = region
        settings.mdmConnections[index].environmentID = environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.mdmConnections[index].tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
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
        current.product = product
        current.baseURL = baseURL
        current.authMethod = authMethod
        current.account = account
        current.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIntune {
            guard let client = IntuneClient(config: current, secret: effectiveSecret, log: log) else {
                statusMessage = "Enter a tenant ID, client ID and client secret first."
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
            return
        }
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
