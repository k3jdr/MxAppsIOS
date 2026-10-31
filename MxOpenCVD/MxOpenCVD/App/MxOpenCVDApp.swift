import SwiftUI

@main
enum Entry {
    static func main() {
        if BatchMode.runIfRequested() { return }
        MxOpenCVDApp.main()
    }
}

struct MxOpenCVDApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("MxOpenCVD", id: "main") {
            MainView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            QuickHelpCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Job") { model.newJob() }.keyboardShortcut("n")
                Button("Open Job…") { model.openJob() }.keyboardShortcut("o")
                Divider()
                Button("Open Image…") { model.openImage() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Job") { model.saveJob() }.keyboardShortcut("s")
                Button("Save Job As…") { model.saveJobAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Save Snapshot…") { model.saveSnapshot() }.keyboardShortcut("s", modifiers: [.command, .option])
                Button("Export Results…") { model.exportLog() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("Inspect") {
                Button("Trigger Inspection") { model.trigger() }.keyboardShortcut("t")
                Button(model.mode == .inspect ? "Stop Live Inspection" : "Start Live Inspection") {
                    model.mode = model.mode == .inspect ? .preview : .inspect
                }
                .keyboardShortcut("r")
                Button(model.frozenFrame == nil ? "Freeze Image" : "Return to Live") { model.toggleFreeze() }.keyboardShortcut("f")
                Divider()
                Button("Clear Results") { model.clearLog() }
            }
        }
    }
}
