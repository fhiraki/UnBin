import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, first.lowercased().hasSuffix(".cue"), !first.hasPrefix("--") {
            exit(runCLI(args))
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            exit(snapshot(to: args[i + 1], rest: Array(args[(i + 2)...])))
        }
        UnBinApp.main()
    }

    static func snapshot(to path: String, rest: [String]) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if rest.contains("dark") { app.appearance = NSAppearance(named: .darkAqua) }
        let model = Model()
        if let cue = rest.first(where: { !["dark", "running", "done"].contains($0) }) {
            model.open(URL(fileURLWithPath: cue))
            model.inspect(wait: true)
        }
        if rest.contains("running") {
            model.running = true
            model.progress = 0.4
            model.current = model.jobs.first?.output.lastPathComponent ?? ""
        }
        if rest.contains("done") {
            model.finished = model.jobs.map { $0.output }
            model.message = model.doneMessage(model.jobs.count)
        }
        let size = NSRect(x: 0, y: 0, width: 640, height: 520)
        let view = NSHostingView(rootView: ContentView(model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.wantsLayer = true
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        window.displayIfNeeded()
        CATransaction.flush()
        let scale = 2
        guard let layer = view.layer,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                         pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 1 }
        let cg = context.cgContext
        cg.setFillColor(NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)?.cgColor ?? .white)
        cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        cg.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if layer.isGeometryFlipped || view.isFlipped {
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        return 0
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct UnBinApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = Model()

    var body: some Scene {
        Window("UnBin", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 500)
                .onOpenURL { model.open($0) }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("cue を開く…", "Open cue…")) { model.chooseCue() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class Player {
    var onChange: ((Int?) -> Void)?
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "unbin.player")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    private var attached = false
    private var generation = 0
    private var handle: FileHandle?
    private var track: CueTrack?
    private var remaining: UInt64 = 0
    private var current: Int?

    func toggle(_ track: CueTrack) {
        let same = current == track.number
        stop()
        let size = UInt64(track.sectorSize)
        guard !same, track.isAudio, size >= 2352, track.length >= size,
              let handle = try? FileHandle(forReadingFrom: track.file),
              (try? handle.seek(toOffset: track.start)) != nil else { return }
        if !attached {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            attached = true
        }
        guard (try? engine.start()) != nil else { return }
        queue.sync {
            generation += 1
            self.handle = handle
            self.track = track
            remaining = track.length / size * size
            feed(generation)
            feed(generation)
        }
        node.play()
        current = track.number
        onChange?(current)
    }

    func stop() {
        queue.sync {
            generation += 1
            try? handle?.close()
            handle = nil
        }
        if attached {
            node.stop()
            engine.stop()
        }
        if current != nil {
            current = nil
            onChange?(nil)
        }
    }

    private func finish(_ g: Int) {
        DispatchQueue.main.async {
            if self.queue.sync(execute: { g == self.generation }) { self.stop() }
        }
    }

    private func feed(_ g: Int) {
        guard g == generation, let handle, let track, remaining > 0 else { return }
        let size = track.sectorSize
        let want = Int(min(remaining, UInt64(size * 75)))
        let frames = want / size * 588
        guard let chunk = try? handle.read(upToCount: want), chunk.count == want,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else {
            remaining = 0
            finish(g)
            return
        }
        remaining -= UInt64(want)
        let high = track.fileType == "MOTOROLA" ? 0 : 1
        chunk.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            var frame = 0
            for sector in 0..<(want / size) {
                var i = sector * size
                for _ in 0..<588 {
                    for channel in 0..<2 {
                        let value = Int16(bitPattern: UInt16(p[i + high]) << 8 | UInt16(p[i + 1 - high]))
                        channels[channel][frame] = Float(value) / 32768
                        i += 2
                    }
                    frame += 1
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let last = remaining == 0
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.queue.async {
                guard let self, g == self.generation else { return }
                if last { self.finish(g) } else { self.feed(g) }
            }
        }
    }
}

final class Model: ObservableObject {
    @Published var playing: Int?
    let player = Player()

    init() {
        player.onChange = { [weak self] number in self?.playing = number }
    }

    @Published var sheet: CueSheet?
    @Published var volumes: [Int: VolumeInfo] = [:]
    @Published var reports: [Int: TrackReport] = [:]
    @Published var alignments: [Int: Alignment] = [:]
    @Published var align = true
    @Published var merge = false
    @Published var outputDir: URL?
    @Published var makeISO = true
    @Published var makeWAV = true
    @Published var running = false
    @Published var progress = 0.0
    @Published var current = ""
    @Published var message = ""
    @Published var failed = false
    @Published var finished: [URL] = []
    private var cancel = CancelFlag()
    private var inspection = CancelFlag()

    var hasData: Bool { sheet?.tracks.contains { !$0.isAudio } ?? false }
    var hasAudio: Bool { sheet?.tracks.contains { $0.isAudio } ?? false }

    func warnings(_ track: CueTrack) -> [String] {
        Converter.warnings(track, reports[track.number], alignments[track.number], volumes[track.number])
    }

    func info(_ track: CueTrack) -> [String] {
        Converter.info(track, alignments[track.number], align: align, merge: merge)
    }

    var needsAlignment: Bool { alignments.values.contains { $0.pad > 0 } }

    var hasWarnings: Bool { sheet?.tracks.contains { !warnings($0).isEmpty } ?? false }

    func inspect(wait: Bool = false) {
        inspection.cancel()
        let flag = CancelFlag()
        inspection = flag
        reports = [:]
        guard let tracks = sheet?.tracks else { return }
        let work = {
            for track in tracks {
                guard let report = Converter.inspect(track, cancel: flag) else { continue }
                let apply = { if !flag.isCancelled { self.reports[track.number] = report } }
                if wait { apply() } else { DispatchQueue.main.async(execute: apply) }
            }
        }
        if wait { work() } else { DispatchQueue.global(qos: .utility).async(execute: work) }
    }

    var jobs: [ConvertJob] {
        guard let sheet, let outputDir else { return [] }
        return Converter.plan(sheet, to: outputDir, iso: makeISO, wav: makeWAV, alignments: align ? alignments : [:],
                              merge: align && merge)
    }

    func open(_ dropped: URL) {
        guard !running else { return }
        player.stop()
        finished = []
        var url = dropped
        if url.pathExtension.lowercased() != "cue" {
            guard let found = CueSheet.find(referencing: url) else {
                sheet = nil
                fail(L("このファイルを指す .cue が同じフォルダに見つかりません。.cue を指定してください",
                       "No .cue in the same folder refers to this file. Please choose the .cue"))
                return
            }
            url = found
        }
        do {
            let loaded = try CueSheet.load(url)
            sheet = loaded
            outputDir = url.deletingLastPathComponent()
            volumes = [:]
            alignments = [:]
            for track in loaded.tracks where !track.isAudio {
                let alignment = Converter.alignment(track)
                alignments[track.number] = alignment
                volumes[track.number] = Converter.volume(track, pad: alignment.pad)
            }
            merge = Converter.canMerge(loaded, alignments)
            message = Converter.discNotes(loaded).joined(separator: "\n")
            failed = false
            inspect()
        } catch {
            sheet = nil
            fail(error.localizedDescription)
        }
    }

    func chooseCue() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cue") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = outputDir
        if panel.runModal() == .OK, let url = panel.url { outputDir = url }
    }

    func start() {
        let jobs = self.jobs
        guard !jobs.isEmpty, !running else { return }
        let existing = jobs.filter { FileManager.default.fileExists(atPath: $0.output.path) }
        if !existing.isEmpty {
            let alert = NSAlert()
            alert.messageText = L("同じ名前のファイルがあります。上書きしますか?", "Some output files already exist. Overwrite them?")
            alert.informativeText = existing.map { $0.output.lastPathComponent }.joined(separator: "\n")
            alert.addButton(withTitle: L("上書き", "Overwrite"))
            alert.addButton(withTitle: L("キャンセル", "Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        cancel = CancelFlag()
        let flag = cancel
        running = true
        failed = false
        finished = []
        progress = 0
        message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<[Int: TrackReport], Error> = .success([:])
            do {
                result = .success(try Converter.run(jobs, cancel: flag) { value, name in
                    DispatchQueue.main.async {
                        self.progress = value
                        self.current = name
                    }
                })
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.running = false
                self.current = ""
                switch result {
                case .success(let reports):
                    self.inspection.cancel()
                    for (number, report) in reports { self.reports[number] = report }
                    self.finished = jobs.map { $0.output }
                    self.message = self.doneMessage(jobs.count)
                case .failure(let error):
                    if error is Cancelled {
                        self.message = L("中止しました", "Cancelled")
                    } else {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    func stop() { cancel.cancel() }

    func doneMessage(_ count: Int) -> String {
        var text = L("\(count) 個のファイルを書き出しました", "Wrote \(count) file(s)")
        if hasWarnings { text += L(" (警告があります。一覧を確かめてください)", " (with warnings; check the list)") }
        return text
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(finished)
    }

    private func fail(_ text: String) {
        message = text
        failed = true
    }
}

struct TrackIcon: View {
    @ObservedObject var model: Model
    let track: CueTrack
    @State private var hovering = false

    var body: some View {
        if track.isAudio {
            let playing = model.playing == track.number
            Button { model.player.toggle(track) } label: {
                Image(systemName: playing ? (hovering ? "stop.fill" : "speaker.wave.2.fill") : (hovering ? "play.fill" : "music.note"))
                    .frame(width: 18, height: 18)
                    .foregroundStyle(Color.pink)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(playing ? L("停止", "Stop") : L("試聴", "Preview"))
        } else {
            Image(systemName: "doc.zipper")
                .frame(width: 18, height: 18)
                .foregroundStyle(Color.blue)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            if let sheet = model.sheet {
                trackList(sheet)
                options
            }
            footer
        }
        .padding(20)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.open(url) } }
            }
            return true
        }
    }

    private var chooseButton: some View {
        Button(L("cue を選ぶ…", "Choose cue…")) { model.chooseCue() }
            .disabled(model.running)
    }

    private var dropZone: some View {
        Group {
            if let sheet = model.sheet {
                HStack(spacing: 14) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sheet.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                        Text(sheet.url.deletingLastPathComponent().path)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    chooseButton
                }
                .padding(16)
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text(L(".cue ファイルをここにドロップ", "Drop a .cue file here")).font(.title2.weight(.semibold))
                    Text(L("cue+bin の CD イメージを ISO と WAV に変換します\nbin ファイルは cue と同じフォルダに置いてください",
                           "Converts a cue+bin CD image to ISO and WAV\nKeep the bin files in the same folder as the cue"))
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    chooseButton.padding(.top, 6)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4),
                              style: StrokeStyle(lineWidth: 2, dash: [6]))
        )
    }

    private func trackList(_ sheet: CueSheet) -> some View {
        let outputs = Dictionary(uniqueKeysWithValues: model.jobs.flatMap { $0.parts }.map { ($0.track.number, $0.output.lastPathComponent) })
        return List(sheet.tracks) { track in
            HStack(spacing: 10) {
                TrackIcon(model: model, track: track)
                Text(String(format: "%02d", track.number)).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(describe(track))
                    if let name = outputs[track.number] {
                        Text("→ " + name).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(L("書き出さない", "Skipped")).font(.caption).foregroundStyle(.tertiary)
                    }
                    ForEach(model.info(track), id: \.self) { text in
                        Label(text, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(model.warnings(track), id: \.self) { text in
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(track.length), countStyle: .file))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(minHeight: 160)
    }

    private func describe(_ track: CueTrack) -> String {
        if track.mode == "CDG" { return L("音声 + CD+G  ", "Audio + CD+G  ") + track.duration }
        if track.isAudio { return L("音声 (CD-DA)  ", "Audio (CD-DA)  ") + track.duration }
        var text = L("データ ", "Data ") + track.mode
        if let volume = model.volumes[track.number]?.description {
            text += "  " + volume
        } else {
            text += L("  (ファイルシステム不明。取り出しはできます)", "  (unknown filesystem; extraction still works)")
        }
        return text
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("データトラックを ISO にする", "Convert data tracks to ISO"), isOn: $model.makeISO)
                .disabled(!model.hasData)
            if model.needsAlignment {
                Toggle(L("LBA 0 以外から始まるデータトラックを位置合わせする (マウントできる ISO にする)",
                         "Align data tracks that do not start at LBA 0 (so that the ISO mounts)"), isOn: $model.align)
                    .disabled(!model.makeISO)
            }
            Toggle(L("音声トラックを WAV にする (ISO には音声を入れられません)",
                     "Convert audio tracks to WAV (an ISO cannot hold audio)"), isOn: $model.makeWAV)
                .disabled(!model.hasAudio)
            HStack {
                Text(L("保存先:", "Save to:"))
                Text(model.outputDir?.path ?? "").lineLimit(1).truncationMode(.head).foregroundStyle(.secondary)
                Spacer()
                Button(L("変更…", "Change…")) { model.chooseOutput() }
            }
        }
        .disabled(model.running)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.running {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: model.progress)
                    Text(model.current).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Button(L("中止", "Cancel")) { model.stop() }
            } else {
                Text(model.message)
                    .foregroundStyle(model.failed ? Color.red : Color.secondary)
                    .lineLimit(2)
                Spacer()
                if !model.finished.isEmpty {
                    Button(L("Finder で表示", "Show in Finder")) { model.reveal() }
                }
                if model.sheet != nil {
                    Button(L("変換", "Convert")) { model.start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.jobs.isEmpty)
                }
            }
        }
    }
}
