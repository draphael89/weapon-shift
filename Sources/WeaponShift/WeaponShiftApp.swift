import AppKit
import SpriteKit
import SwiftUI

@main
struct WeaponShiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var game = GameStore()

    var body: some Scene {
        WindowGroup {
            ContentView(game: game)
                .frame(minWidth: 960, minHeight: 540)
                .background(Color.black)
                .ignoresSafeArea()
                .onAppear { appDelegate.activate() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Run") {
                Button(game.pauseSheetPresented ? "Resume" : "Pause") {
                    game.togglePause()
                }
                .keyboardShortcut("p", modifiers: [])

                Button("Restart") {
                    game.restartRun()
                }
                .keyboardShortcut("r", modifiers: [])

                Divider()

                Button("Settings...") {
                    game.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var playtestWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        activate()
        launchPlaytestHarnessIfNeeded()
    }

    func activate() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func launchPlaytestHarnessIfNeeded() {
        let isPlaytest = CommandLine.arguments.contains("--playtest") || ProcessInfo.processInfo.environment["WEAPONSHIFT_PLAYTEST"] == "1"
        guard isPlaytest else { return }

        let view = SKView(frame: CGRect(x: 0, y: 0, width: 960, height: 540))
        let scene = DungeonScene(size: CGSize(width: 480, height: 270))
        view.presentScene(scene)

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        window.orderOut(nil)
        playtestWindow = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            scene.startAutomatedPlaytest()
        }
    }
}

@MainActor
final class GameStore: ObservableObject {
    @Published var pauseSheetPresented = false
    @Published var settingsPresented = false
    @Published var reduceShake = false
    @Published var highContrastHUD = false

    weak var scene: DungeonScene?

    func attach(scene: DungeonScene) {
        self.scene = scene
        scene.shell = self
        applySettings()
    }

    func togglePause() {
        pauseSheetPresented ? resume() : pause()
    }

    func pause() {
        pauseSheetPresented = true
        scene?.setShellPaused(true)
    }

    func resume() {
        pauseSheetPresented = false
        scene?.setShellPaused(false)
    }

    func restartRun() {
        pauseSheetPresented = false
        scene?.setShellPaused(false)
        scene?.restartRun()
    }

    func showSettings() {
        pauseSheetPresented = false
        scene?.setShellPaused(true)
        settingsPresented = true
    }

    func closeSettings() {
        settingsPresented = false
        if !pauseSheetPresented {
            scene?.setShellPaused(false)
        }
    }

    func applySettings() {
        scene?.reduceShake = reduceShake
        scene?.highContrastHUD = highContrastHUD
    }
}

struct ContentView: View {
    @ObservedObject var game: GameStore

    var body: some View {
        PixelGameView(store: game)
            .background(Color.black)
            .sheet(isPresented: $game.pauseSheetPresented) {
                PauseSheet(game: game)
                    .frame(width: 360, height: 240)
                    .background(Color(red: 0.07, green: 0.06, blue: 0.055))
            }
            .sheet(isPresented: $game.settingsPresented) {
                SettingsSheet(game: game)
                    .frame(width: 420, height: 260)
                    .background(Color(red: 0.07, green: 0.06, blue: 0.055))
            }
    }
}

struct PauseSheet: View {
    @ObservedObject var game: GameStore

    var body: some View {
        VStack(spacing: 18) {
            Text("Paused")
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            VStack(spacing: 10) {
                Button("Resume") { game.resume() }
                    .keyboardShortcut(.defaultAction)
                Button("Restart Run") { game.restartRun() }
                Button("Settings") { game.showSettings() }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(28)
    }
}

struct SettingsSheet: View {
    @ObservedObject var game: GameStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(.system(size: 24, weight: .black, design: .monospaced))
                .foregroundStyle(.white)

            Toggle("Reduce screen shake", isOn: $game.reduceShake)
            Toggle("High contrast pixel HUD", isOn: $game.highContrastHUD)

            Spacer()

            HStack {
                Spacer()
                Button("Done") {
                    game.applySettings()
                    game.closeSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .toggleStyle(.checkbox)
        .foregroundStyle(.white)
        .padding(26)
        .onChange(of: game.reduceShake) { _, _ in game.applySettings() }
        .onChange(of: game.highContrastHUD) { _, _ in game.applySettings() }
    }
}

struct PixelGameView: NSViewRepresentable {
    @ObservedObject var store: GameStore

    func makeNSView(context: Context) -> PixelViewportView {
        PixelViewportView(store: store)
    }

    func updateNSView(_ nsView: PixelViewportView, context: Context) {
        nsView.scene.reduceShake = store.reduceShake
        nsView.scene.highContrastHUD = store.highContrastHUD
    }
}

final class PixelViewportView: NSView {
    let scene: DungeonScene
    private let skView = SKView()
    private let internalSize = CGSize(width: 480, height: 270)
    private let snapshotMode = appArgumentValue(after: "--snapshot")
    private let snapshotPath = appArgumentValue(after: "--snapshot-path")

    init(store: GameStore) {
        scene = DungeonScene(size: internalSize)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        skView.presentScene(scene)
        skView.ignoresSiblingOrder = true
        skView.preferredFramesPerSecond = 60
        skView.shouldCullNonVisibleNodes = true
        skView.allowsTransparency = false
        skView.wantsLayer = true
        skView.layer?.magnificationFilter = .nearest
        skView.layer?.minificationFilter = .nearest
        skView.scene?.scaleMode = .fill
        addSubview(skView)

        store.attach(scene: scene)
        scheduleSnapshotIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.titleVisibility = .hidden
        window?.titlebarAppearsTransparent = true
        window?.styleMask.insert(.fullSizeContentView)
        window?.makeFirstResponder(self)
    }

    override func layout() {
        super.layout()
        let scale = max(1, floor(min(bounds.width / internalSize.width, bounds.height / internalSize.height)))
        let size = CGSize(width: internalSize.width * scale, height: internalSize.height * scale)
        skView.frame = CGRect(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }

    override func keyDown(with event: NSEvent) {
        scene.handleKey(event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        scene.handleKey(event, isDown: false)
    }

    override func flagsChanged(with event: NSEvent) {
        scene.handleFlags(event.modifierFlags)
    }

    private func scheduleSnapshotIfNeeded() {
        guard let snapshotMode, let snapshotPath else { return }
        _ = snapshotMode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.writeSnapshot(to: snapshotPath)
        }
    }

    private func writeSnapshot(to path: String) {
        layoutSubtreeIfNeeded()
        guard
            let texture = skView.texture(from: scene),
            let data = pngData(from: texture)
        else {
            fputs("snapshot failed\n", stderr)
            NSApp.terminate(nil)
            return
        }

        do {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            fputs("snapshot write failed: \(error)\n", stderr)
        }
        NSApp.terminate(nil)
    }
}

private func appArgumentValue(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard CommandLine.arguments.indices.contains(valueIndex) else { return nil }
    return CommandLine.arguments[valueIndex]
}

private func pngData(from texture: SKTexture) -> Data? {
    let image = NSImage(cgImage: texture.cgImage(), size: texture.size())
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
    return bitmap.representation(using: .png, properties: [:])
}
