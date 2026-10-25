import AppKit
import SwiftUI

struct Profile: Identifiable, Decodable {
    let id: String
    let name: String
    let display_name: String
    let root: String
    let stage: String
    let prepared: Bool
    let game_prepared: Bool
    let steam_running: Bool
    let game_running: Bool
    let last_error: String
    let process_count: Int
    let startup_state: String?
    let startup_note: String?
    var status: String {
        if startup_state == "checking" { return "Checking Steam startup…" }
        if startup_state == "failed" { return "Startup stopped" }
        if game_running { return "StarBreak running" }
        if steam_running { return "Steam running" }
        if process_count > 0 { return "Background helper running" }
        if prepared { return "Ready to start" }
        if stage == "preparation_failed" { return "Preparation failed" }
        return "Needs preparation"
    }
    var running: Bool { process_count > 0 }
}

struct ProfileList: Decodable {
    let profiles: [Profile]
    let data_root: String
    let launch_pause_reason: String?
}

struct Reply: Decodable {
    let ok: Bool
    let error: String?
    let result: ProfileList?
}

struct BackendError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Backend {
    static func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let resources = Bundle.main.resourceURL else {
                        throw BackendError(message: "The application resources are missing.")
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                    process.arguments = [resources.appendingPathComponent("app_backend.py").path] + arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["MSI_ISOLATION_LIBRARY"] = resources.appendingPathComponent("libmacsteam_isolation.dylib").path
                    environment["PYTHONDONTWRITEBYTECODE"] = "1"
                    process.environment = environment
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw BackendError(message: "The profile manager returned an invalid response.")
                    }
                    guard object["ok"] as? Bool == true else {
                        throw BackendError(message: object["error"] as? String ?? "The operation failed.")
                    }
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selectedID: String?
    @Published var busy = false
    @Published var activity = ""
    @Published var error: String?
    @Published var addSheet = false
    @Published var newName = ""
    @Published var note = "Add a profile for each Steam account."
    @Published var launchPauseReason: String?
    private var refreshing = false
    let snapshot = ProcessInfo.processInfo.arguments.contains("--ui-snapshot")
    var selected: Profile? { profiles.first { $0.id == selectedID } }
    var runningCount: Int { profiles.filter { $0.running }.count }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let data = try await Backend.run(["list"])
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            profiles = reply.result?.profiles ?? []
            launchPauseReason = reply.result?.launch_pause_reason
            if selected == nil { selectedID = profiles.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func perform(_ command: String, name: String, message: String) {
        guard !busy else { return }
        busy = true
        activity = message
        error = nil
        Task {
            do {
                _ = try await Backend.run([command, name])
                switch command {
                case "create": note = "Profile added. Prepare it before starting Steam."
                case "prepare": note = "Private Steam and StarBreak files are prepared."
                case "launch-steam": note = "Waiting up to 60 seconds for Steam’s sign-in window. A failed start stops this profile automatically."
                case "launch-game": note = "StarBreak is starting with this profile’s SBPE settings."
                case "stop": note = "This profile’s Steam and StarBreak have quit."
                default: break
                }
                await refresh()
                if command == "create" {
                    selectedID = profiles.first { $0.display_name == name }?.id
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
            activity = ""
        }
    }

    func createProfile() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        addSheet = false
        newName = ""
        perform("create", name: name, message: "Creating profile…")
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}

private let mint = Color(red: 0.40, green: 0.90, blue: 0.75)
private let surface = Color(red: 0.105, green: 0.125, blue: 0.15)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 248, maxWidth: 300)
            detail.frame(minWidth: 650, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 650)
        .background(Color(red: 0.065, green: 0.08, blue: 0.10))
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.addSheet) { addProfile }
        .task { await model.refresh() }
        .onReceive(timer) { _ in
            if !model.busy { Task { await model.refresh() } }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.square")
                    .font(.system(size: 27, weight: .medium)).foregroundStyle(mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacSteam").font(.system(size: 20, weight: .semibold))
                    Text("ISOLATION").font(.system(size: 10, weight: .bold)).tracking(2.1).foregroundStyle(.secondary)
                }
            }.padding(24)
            HStack {
                Text("PROFILES").font(.system(size: 10, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.profiles.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.profiles) { profile in
                        Button {
                            model.selectedID = profile.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.square.fill")
                                    .font(.system(size: 25)).foregroundStyle(model.selectedID == profile.id ? mint : .gray)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.display_name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    Text(profile.status).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if profile.running { Circle().fill(mint).frame(width: 6, height: 6) }
                            }
                            .padding(13)
                            .background(model.selectedID == profile.id ? mint.opacity(0.10) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.busy)
                    }
                }.padding(.horizontal, 12)
            }
            Button {
                model.newName = "Steam \(model.profiles.count + 1)"
                model.addSheet = true
            } label: {
                Label("Add profile", systemImage: "plus").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).controlSize(.large).disabled(model.busy).padding(18)
            Divider()
            HStack {
                Circle().fill(model.runningCount > 0 ? mint : .gray).frame(width: 6, height: 6)
                Text("\(model.runningCount) profiles running").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).help("Refresh status").disabled(model.busy)
            }.padding(20)
        }.background(Color(red: 0.085, green: 0.10, blue: 0.12))
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Label("ACCOUNT WORKSPACE", systemImage: "square.stack.3d.up")
                        .font(.system(size: 10, weight: .bold)).tracking(1.4).foregroundStyle(mint)
                    Spacer()
                    Text("PREVIEW").font(.system(size: 9, weight: .bold)).tracking(1.1)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Color.white.opacity(0.07)).clipShape(Capsule())
                }
                if let profile = model.selected {
                    profileDetail(profile)
                } else {
                    Text("Your Steam accounts, side by side.")
                        .font(.system(size: 29, weight: .semibold))
                    Text("Create a profile for each account, then prepare its private Steam and StarBreak files.")
                        .foregroundStyle(.secondary)
                    Button("Create first profile") { model.addSheet = true }
                        .buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(Color.orange)
                        .textSelection(.enabled).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 9))
                }
                if let reason = model.launchPauseReason {
                    Label(reason, systemImage: "pause.circle")
                        .font(.system(size: 12)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Each private Steam appears in the Dock as “Steam (profile name)” and runs alongside your normal Steam. Use Stop profile to quit it. Account sign-in and SBPE gameplay still need testing.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if model.busy {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text(model.activity).font(.system(size: 12))
                    }.padding(.top, 3)
                } else {
                    Text(model.note).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(32)
        }
    }

    private func profileDetail(_ profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(profile.display_name).font(.system(size: 32, weight: .semibold))
                Text("A separate Steam login and StarBreak workspace.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                statusTile("STEAM", value: profile.steam_running ? "Running" : "Stopped", symbol: "power", active: profile.steam_running)
                statusTile("STARBREAK + SBPE", value: profile.game_running ? "Running" : (profile.game_prepared ? "Prepared" : "Not prepared"), symbol: "gamecontroller", active: profile.game_running)
            }
            if let note = profile.startup_note, !note.isEmpty {
                Label(note, systemImage: profile.startup_state == "failed" ? "exclamationmark.circle" : "clock")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                actionRow(number: "1", title: "Prepare this profile", description: "Create private app files and copy your Mac SBPE settings.") {
                    Button(profile.prepared ? "Prepare again" : "Prepare") {
                        model.perform("prepare", name: profile.name, message: "Preparing private copies… This may take a minute.")
                    }.disabled(model.busy || profile.running)
                }
                Divider().padding(.leading, 56)
                actionRow(number: "2", title: "Start Steam", description: "Sign in to the account you want to use for this profile.") {
                    Button(profile.steam_running ? "Running" : "Start Steam") {
                        model.perform("launch-steam", name: profile.name, message: "Starting private Steam…")
                    }.disabled(model.busy || model.launchPauseReason != nil || !profile.prepared || profile.steam_running || profile.startup_state == "checking")
                }
                Divider().padding(.leading, 56)
                actionRow(number: "3", title: "Launch StarBreak", description: "Launch with Mac SBPE, private controls and separate logs.") {
                    Button(profile.game_running ? "Running" : "Launch with SBPE") {
                        model.perform("launch-game", name: profile.name, message: "Starting StarBreak with SBPE…")
                    }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
                        .disabled(model.busy || !profile.steam_running || !profile.game_prepared || profile.game_running || profile.startup_state != "passed")
                }
            }.background(surface).clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button { model.reveal(profile.root) } label: { Label("Profile files & logs", systemImage: "folder") }
                    .disabled(model.busy)
                Spacer()
                Button {
                    model.perform("stop", name: profile.name, message: "Asking this profile’s Steam to quit…")
                } label: { Label("Stop profile", systemImage: "stop.fill") }
                    .disabled(model.busy || !profile.running)
                    .help("Close Steam and StarBreak belonging to this profile.")
            }.controlSize(.large)
            if !profile.last_error.isEmpty {
                Text(profile.last_error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }

    private func statusTile(_ title: String, value: String, symbol: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(active ? mint : .secondary)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Text(value).font(.system(size: 15, weight: .medium))
            }
            Spacer(minLength: 0)
        }.padding(17).frame(maxWidth: .infinity).background(surface).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func actionRow<Actions: View>(number: String, title: String, description: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 14) {
            Text(number).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(mint).frame(width: 25, height: 25)
                .background(mint.opacity(0.08)).clipShape(Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actions().controlSize(.large).frame(minWidth: 118)
        }.padding(19)
    }

    private var addProfile: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add a Steam profile").font(.title2.weight(.semibold))
            Text("Use a name that helps you recognize the account.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Profile name", text: $model.newName).textFieldStyle(.roundedBorder)
                .onSubmit { model.createProfile() }
            HStack {
                Spacer()
                Button("Cancel") { model.addSheet = false }.keyboardShortcut(.cancelAction)
                Button("Add profile") { model.createProfile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(26).frame(width: 400)
    }
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let args = ProcessInfo.processInfo.arguments
        // An image of this app's own window, for layout verification only.
        if let index = args.firstIndex(of: "--ui-snapshot"), args.count > index + 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: args[index + 1]))
                }
                NSApp.terminate(nil)
            }
        }
    }
}

@main struct MacSteamIsolationApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("MacSteam Isolation") {
            ContentView().environmentObject(model)
        }.defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add profile…") { model.addSheet = true }.keyboardShortcut("n")
            }
        }
    }
}
