import SwiftUI
import AppKit

/// The settings form.
///
/// Everything here has a default good enough that most people never open this
/// window, and nothing here can break the tool: the assignment order, the badge
/// rules and the numbering all live in code, out of reach of a stray click.
struct SettingsView: View {

    @ObservedObject var settings = Settings.shared
    var onHotkeysChanged: () -> Void

    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Shortcuts") {
                LabeledContent("Capture a region") {
                    HotkeyRecorder(combo: $settings.captureHotkey)
                        .frame(width: 132, height: 24)
                        .onChange(of: settings.captureHotkey) { _, _ in onHotkeysChanged() }
                }
                LabeledContent("Re-capture the last region") {
                    HotkeyRecorder(combo: $settings.recaptureHotkey)
                        .frame(width: 132, height: 24)
                        .onChange(of: settings.recaptureHotkey) { _, _ in onHotkeysChanged() }
                }
                Text("If a shortcut stops working, another app has claimed it — pick a different one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Capture") {
                Toggle("Outline the frame under the pointer", isOn: $settings.frameSnapEnabled)
                Text("Hover a card or a Figma frame to have its edges found, then click or press ⏎ to take it. Hold ⌥ to ignore it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Unmarked captures", selection: $settings.autoFinishSeconds) {
                    Text("Copy after 3 seconds").tag(3.0)
                    Text("Copy after 6 seconds").tag(6.0)
                    Text("Wait for ⌘C").tag(0.0)
                }
                Text("A capture nobody marks up is a plain screenshot. Left untouched, it copies itself and moves to the corner. Any input at all cancels that.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Corner card", selection: $settings.shelfSeconds) {
                    Text("Put away after 10 seconds").tag(10.0)
                    Text("Put away after 30 seconds").tag(30.0)
                    Text("Keep until dismissed").tag(0.0)
                }
                Text("The card is a handle on a file that is already saved — putting it away never discards anything. Pointing at it stops the countdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Export") {
                Toggle("Include the note legend", isOn: $settings.legendEnabled)
                Picker("Legend position", selection: $settings.legendPlacement) {
                    ForEach(LegendPlacement.allCases) { Text($0.label).tag($0) }
                }
                .disabled(!settings.legendEnabled)
                Toggle("Lift the capture off a background", isOn: $settings.marginedExport)
                Text("Adds a margin and a shadow, so the capture reads as an object rather than running to the edges of the file. Turn it off for pixel-exact screenshots.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Export at 1× for smaller files", isOn: $settings.exportAtOneX)

                LabeledContent("Save captures to") {
                    HStack(spacing: 8) {
                        Text(settings.saveDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Text("Every capture is written here as well as copied, so Claude Code and Codex can be given a path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: 5), spacing: 12) {
                    ForEach(0..<Palette.count, id: \.self) { i in
                        VStack(spacing: 4) {
                            ColorPicker("", selection: binding(for: i), supportsOpacity: false)
                                .labelsHidden()
                            HStack(spacing: 3) {
                                Text("\(Palette.assignmentPosition(i))")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(Palette.displayName(i))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)

                Text("The small number is the order boxes take them — chosen so consecutive boxes never look alike. The prompt names each color from the color itself, so recoloring a slot renames it there too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to the Morandi set") { settings.resetPalette() }
            } header: {
                Text("Palette")
            }

            Section("Prompt") {
                TextEditor(text: $settings.promptTemplate)
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(minHeight: 116)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))

                Text("{{items}} is replaced by the numbered list. Everything around it is yours.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset to the default wording") { settings.resetPromptTemplate() }
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .disabled(!LaunchAtLogin.isAvailable)
                    .onChange(of: launchAtLogin) { _, wanted in
                        launchAtLogin = LaunchAtLogin.set(wanted)
                    }
                if !LaunchAtLogin.isAvailable {
                    Text("Available when running Fetcher.app rather than the development binary.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // Fixed width, free height: the prompt editor is the one thing here
        // someone may want more room for.
        .frame(width: 560)
        .frame(minHeight: 420, idealHeight: 640, maxHeight: .infinity)
    }

    // MARK: Helpers

    private func binding(for index: Int) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: Palette.color(index)) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let hex = String(format: "#%02X%02X%02X",
                                 Int((srgb.redComponent * 255).rounded()),
                                 Int((srgb.greenComponent * 255).rounded()),
                                 Int((srgb.blueComponent * 255).rounded()))
                settings.paletteHex[index] = hex
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveDirectory
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveDirectoryPath = url.path
        }
    }
}

/// Hosts the form in an ordinary window.
///
/// The app is menu-bar-only, so opening settings is the one moment it needs to
/// behave like a regular app — otherwise the window opens behind everything and
/// takes no keyboard.
final class SettingsWindowController: NSWindowController {

    convenience init(onHotkeysChanged: @escaping () -> Void) {
        let hosting = NSHostingController(
            rootView: SettingsView(onHotkeysChanged: onHotkeysChanged))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Fetcher Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 640))
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
