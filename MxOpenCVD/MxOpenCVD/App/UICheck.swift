import AppKit
import SwiftUI

/// Runs the real app model and window off screen, without appearing on the desktop or taking focus: the live
/// camera path in Preview and Inspect, then an opened image, with a picture of the window at each stage.
/// It uses its own job and leaves the saved job, camera choice and Quick Help layout alone. It doesn't exercise clicks.
/// Writes check.json and two PNGs per stage to the folder: the controls, and the camera image with its overlays.
@MainActor
enum UICheck {
    static func run(folder: String, jobPath: String?, imagePath: String?, soakSeconds: Double) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Docked for this run, whatever was saved, so a floating Quick Help window doesn't appear on the desktop.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[QuickHelp.visibleKey] = true
        arguments[QuickHelp.floatingKey] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        var job = Job()
        job.name = "UI Check"
        if let jobPath, let data = FileManager.default.contents(atPath: jobPath), let given = try? JSONDecoder().decode(Job.self, from: data) {
            job = given
        } else {
            job.tools = [ToolConfig(kind: .quality), ToolConfig(kind: .ocr), ToolConfig(kind: .code)]
        }

        let model = AppModel(job: job)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 1360, height: 860),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: MainView(model: model))
        hosting.wantsLayer = true
        window.contentView = hosting
        model.selectedToolID = job.tools.first?.id

        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func write(_ rep: NSBitmapImageRep, _ name: String) {
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
            }
        }
        // Neither way of drawing a window off screen gets all of it: one leaves out the camera layer and the other the controls.
        func picture(_ name: String) {
            guard let view = window.contentView, let layer = view.layer else { return }
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                write(rep, name + "-controls")
            }
            if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
               let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
                context.translateBy(x: 0, y: view.bounds.height)
                context.scaleBy(x: 1, y: -1)
                layer.render(in: context)
                write(rep, name + "-image")
            }
        }
        // CPU use over a stretch of time, as a percentage of one core, and memory at the end of it.
        func measuring(_ seconds: TimeInterval) -> [String: Any] {
            let cpuStart = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
            let wallStart = Date()
            wait(seconds)
            let cpu = Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID) - cpuStart) / 1e9
            return ["cpuPercent": cpu / Date().timeIntervalSince(wallStart) * 100, "memoryMB": memoryFootprintMB()]
        }

        var results: [String: Any] = ["libraries": MXVEngine.libraryVersions()]

        wait(0.5)
        model.startCameras()
        wait(3)
        var previewing = stage(model)
        previewing.merge(measuring(5)) { _, new in new }
        results["preview"] = previewing
        results["cameras"] = model.cameras.map { ["name": $0.name, "tier": $0.tier.role, "deskView": $0.isDeskView] as [String: Any] }
        picture("1-preview")

        let before = model.reportCount
        model.mode = .inspect
        let started = Date()
        let cost = measuring(6)
        let elapsed = Date().timeIntervalSince(started)
        var inspecting = stage(model)
        inspecting.merge(cost) { _, new in new }
        inspecting["reportsPerSecond"] = Double(model.reportCount - before) / elapsed
        inspecting["logRowsAfterInspecting"] = model.log.count
        results["inspect"] = inspecting
        picture("2-inspect")

        // Inspecting for a long stretch: memory should settle rather than keep climbing.
        if soakSeconds > 0 {
            var samples: [Double] = []
            let steps = 12
            for _ in 0..<steps {
                wait(soakSeconds / Double(steps))
                samples.append(memoryFootprintMB())
            }
            results["soak"] = ["seconds": soakSeconds, "memoryMB": samples, "reports": model.reportCount, "logRows": model.log.count] as [String: Any]
        }
        model.mode = .preview

        // Pinning to each camera in turn, as a click on its row would, and back to Auto.
        var pinned: [[String: Any]] = []
        for camera in model.cameras where !camera.isDeskView {
            model.pinCamera(camera.id)
            wait(3)
            var entry = stage(model)
            entry["asked"] = camera.name
            pinned.append(entry)
        }
        model.pinCamera(nil)
        wait(3)
        results["pinned"] = pinned
        results["backToAuto"] = stage(model)

        model.toggleFreeze()
        wait(1)
        var frozen = stage(model)
        frozen["frozen"] = model.frozenFrame != nil
        results["frozen"] = frozen
        model.resumeLive()
        wait(1)

        if let imagePath {
            model.openImage(at: URL(fileURLWithPath: imagePath))
            wait(2)
            var opened = stage(model)
            opened["still"] = model.stillName ?? ""
            opened["texts"] = model.live.report?.tools.flatMap { $0.output.texts } ?? []
            results["image"] = opened
            picture("3-image")

            // What Quick Help shows for a text box under the pointer, and for the longest setting description.
            if let report = model.live.report,
               let text = report.tools.flatMap(\.output.overlays).first(where: { !$0.label.isEmpty && $0.points.count == 4 && $0.label.contains("LOT") }) {
                let middle = CGPoint(x: text.points.map(\.pointValue.x).reduce(0, +) / 4, y: text.points.map(\.pointValue.y).reduce(0, +) / 4)
                let found = AppQuickHelp.found(at: middle, in: report, tolerance: 3)
                results["quickHelpOverText"] = found?.title ?? "nothing"
                QuickHelp.shared.hover(area: found, id: UUID(), true)
                wait(0.5)
                picture("4-quickhelp-found")
            }
            let longest = ToolKind.onnx.params.first { $0.key == "yoloFormat" }!
            QuickHelp.shared.hover(tool: AppQuickHelp.param(longest, of: .onnx), id: UUID(), true)
            wait(0.5)
            results["quickHelpShown"] = QuickHelp.shared.shown?.title ?? "nothing"
            picture("5-quickhelp-long")
            model.trigger()
            wait(1)
            results["logCount"] = model.log.count
            results["latestLog"] = model.log.first?.summary ?? ""
            model.resumeLive()
        }

        if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("check.json"))
        }
    }

    private static func memoryFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private static func stage(_ model: AppModel) -> [String: Any] {
        [
            "camera": model.activeCamera?.name ?? "none",
            "status": model.cameraStatus,
            "format": model.controls.formatDescription,
            "imageWidth": model.live.imageSize.width,
            "imageHeight": model.live.imageSize.height,
            "framesPerSecond": model.live.framesPerSecond,
            "verdict": model.live.report?.verdict.rawValue ?? "none",
            "ms": model.live.report?.totalMs ?? 0,
        ]
    }
}
