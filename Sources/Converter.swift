import Foundation

struct ConvertJob: Identifiable {
    var track: CueTrack
    var output: URL
    var pad: UInt64 = 0
    var more: [ConvertJob] = []
    var id: Int { track.number }
    var parts: [ConvertJob] { [ConvertJob(track: track, output: output, pad: pad)] + more }
}

struct Alignment {
    var pad: UInt64 = 0
    var volume = false
    var fromScan = false
    var unverified = false
}

struct TrackReport {
    var sectors: UInt64 = 0
    var form2: UInt64 = 0
    var badEDC: UInt64 = 0
    var firstBadEDC: UInt64?
    var unsynced: UInt64 = 0
}

struct VolumeInfo {
    var iso = false
    var highSierra = false
    var joliet = false
    var rockRidge = false
    var elTorito = false
    var udf = false
    var hfs = ""
    var label = ""
    var sectors: UInt64?

    var description: String? {
        var parts: [String] = []
        if iso {
            var text = "ISO 9660"
            if joliet { text += " + Joliet" }
            if rockRidge { text += " + Rock Ridge" }
            if elTorito { text += " + El Torito" }
            parts.append(text)
        }
        if highSierra { parts.append("High Sierra") }
        if udf { parts.append("UDF") }
        if !hfs.isEmpty { parts.append(hfs) }
        if parts.isEmpty { return nil }
        var text = parts.joined(separator: " / ")
        if (iso || highSierra) && !hfs.isEmpty { text += L(" ハイブリッド", " hybrid") }
        if !label.isEmpty { text += " “\(label)”" }
        return text
    }
}

final class CancelFlag {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct Cancelled: Error {}

enum Converter {
    static let chunkSectors = 2048

    static func plan(_ sheet: CueSheet, to dir: URL, iso: Bool, wav: Bool,
                     alignments: [Int: Alignment] = [:], merge: Bool = false) -> [ConvertJob] {
        let dataCount = sheet.tracks.filter { !$0.isAudio }.count
        var jobs: [ConvertJob] = []
        var whole: Int?
        for track in sheet.tracks {
            if track.isAudio {
                guard wav else { continue }
                let name = String(format: "%@ (Track %02d).wav", sheet.baseName, track.number)
                jobs.append(ConvertJob(track: track, output: dir.appendingPathComponent(name)))
            } else {
                guard iso else { continue }
                let pad = alignments[track.number]?.pad ?? 0
                if merge {
                    if let whole {
                        jobs[whole].more.append(ConvertJob(track: track, output: jobs[whole].output, pad: pad))
                    } else {
                        whole = jobs.count
                        jobs.append(ConvertJob(track: track, output: dir.appendingPathComponent(sheet.baseName + ".iso"), pad: pad))
                    }
                    continue
                }
                let name = dataCount == 1
                    ? sheet.baseName + ".iso"
                    : String(format: "%@ (Track %02d).iso", sheet.baseName, track.number)
                jobs.append(ConvertJob(track: track, output: dir.appendingPathComponent(name), pad: pad))
            }
        }
        return jobs
    }

    static func discNotes(_ sheet: CueSheet) -> [String] {
        var notes: [String] = []
        if !sheet.tracks.contains(where: { !$0.isAudio }) {
            notes.append(L("音声だけのディスクです。ISO は音声を持てないので、WAV だけを書き出します",
                           "This is an audio-only disc. An ISO cannot hold audio, so only WAV files are written"))
        }
        return notes
    }

    static func info(_ track: CueTrack, _ alignment: Alignment?, align: Bool, merge: Bool = false) -> [String] {
        if track.number == 0 {
            return [L("トラック 1 の前に隠れている音声 (隠しトラック) です", "Hidden audio found before track 1")]
        }
        if track.isAudio {
            return track.flags.contains("PRE")
                ? [L("プリエンファシス付きの録音です。補正せずに書き出すので、高音が強く聞こえます",
                     "Recorded with pre-emphasis. It is written as is, so the treble sounds boosted")]
                : []
        }
        if merge && align {
            return [L("マルチセッションのディスクです。全セッションをディスク上の位置に並べて、1 本の ISO にまとめます",
                      "Multisession disc. All sessions are placed at their disc positions in a single ISO")]
        }
        guard let alignment, alignment.pad > 0 else { return [] }
        if !align {
            return [L("ディスクの LBA \(alignment.pad) から始まるトラックです。位置合わせをしないので、この ISO はそのままではマウントできません",
                      "This track starts at disc LBA \(alignment.pad). Without alignment the ISO cannot be mounted as is")]
        }
        return [L("ディスクの LBA \(alignment.pad) から始まるトラックです。先頭に同じ長さの空きを入れて、マウントできる ISO にします",
                  "This track starts at disc LBA \(alignment.pad). The ISO is padded by that many empty sectors so that it mounts")]
    }

    static func warnings(_ track: CueTrack, _ report: TrackReport?, _ alignment: Alignment? = nil,
                         _ volume: VolumeInfo? = nil) -> [String] {
        var list: [String] = []
        if track.isAudio && track.flags.contains("4CH") {
            list.append(L("4 チャンネルの音声です。WAV は 2 チャンネルとして書くので、正しく再生できません",
                          "Four-channel audio. The WAV is written as two channels and will not play correctly"))
        }
        if let alignment, alignment.unverified {
            list.append(L("ディスクの LBA 0 以外から始まるトラックですが、ファイルシステムの位置を確かめられません。位置合わせをしないので、マウントできない可能性があります",
                          "This track does not start at disc LBA 0, but the filesystem position could not be confirmed. No alignment is applied; the ISO may not mount"))
        }
        let rest = track.length % UInt64(track.sectorSize)
        if rest != 0 {
            list.append(L("トラックの長さがセクタの大きさ (\(track.sectorSize)) で割り切れません。末尾の \(rest) バイトは捨てます",
                          "The track length is not a multiple of the sector size (\(track.sectorSize)). The last \(rest) bytes are dropped"))
        }
        if let report, report.form2 > 0 {
            list.append(L("フォーム 2 のセクタが \(report.form2) 個あります (全 \(report.sectors) 個)。ISO ではその部分の動画・音声データが欠けます。完全な写しには元のイメージを残してください",
                          "\(report.form2) of \(report.sectors) sectors are Mode 2 Form 2. Their video/audio data is truncated in the ISO. Keep the original image for a complete copy"))
        }
        if let report, report.badEDC > 0 {
            let first = report.firstBadEDC ?? 0
            list.append(L("EDC (誤り検出符号) の合わないセクタが \(report.badEDC) 個あります (最初はトラックの \(first) セクタ目)。イメージが壊れているか、意図的に入れられた誤りセクタです。その部分のデータは正しくない可能性があります",
                          "\(report.badEDC) sectors fail the EDC check (first at track sector \(first)). The image is damaged or has intentional bad sectors; data there may be wrong"))
        }
        if let report, report.unsynced > 0 {
            list.append(L("同期信号の無いセクタが \(report.unsynced) 個あります。データとして読めない部分です",
                          "\(report.unsynced) sectors have no sync pattern and cannot be read as data"))
        }
        if let volume, let expected = volume.sectors, alignment?.unverified != true {
            let have = track.length / UInt64(track.sectorSize) + (alignment?.pad ?? 0)
            if expected > have {
                list.append(L("ボリュームは \(expected) セクタあるはずですが、イメージは \(have) セクタしかありません。途中で切れている可能性があります",
                              "The volume claims \(expected) sectors but the image has only \(have). It may be truncated"))
            }
        }
        return list
    }

    private static let edcTable: [UInt32] = (0..<256).map { i in
        var e = UInt32(i)
        for _ in 0..<8 { e = (e >> 1) ^ (e & 1 != 0 ? 0xD801_8001 : 0) }
        return e
    }

    private static func edc(_ p: UnsafePointer<UInt8>, _ count: Int) -> UInt32 {
        edcTable.withUnsafeBufferPointer { table in
            var e: UInt32 = 0
            for i in 0..<count { e = table[Int((e ^ UInt32(p[i])) & 0xFF)] ^ (e >> 8) }
            return e
        }
    }

    private static func stored(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
    }

    static func examine(sector: UnsafePointer<UInt8>, track: CueTrack, index: UInt64, report: inout TrackReport) {
        var bad = false
        func subheader(_ sub: UnsafePointer<UInt8>) {
            for i in 0..<4 where sub[i] != sub[i + 4] { return }
            if sub[2] & 0x20 != 0 {
                report.form2 += 1
                let value = stored(sub + 2332)
                bad = value != 0 && edc(sub, 2332) != value
            } else {
                bad = edc(sub, 2056) != stored(sub + 2056)
            }
        }
        switch track.sectorSize {
        case 2336:
            subheader(sector)
        case 2352, 2448:
            if !isSynced(sector) {
                report.unsynced += 1
            } else if sector[15] == 1 {
                bad = edc(sector, 2064) != stored(sector + 2064)
            } else if sector[15] == 2 {
                subheader(sector + 16)
            }
        default:
            break
        }
        if bad {
            report.badEDC += 1
            if report.firstBadEDC == nil { report.firstBadEDC = index }
        }
    }

    private static func isSynced(_ sector: UnsafePointer<UInt8>) -> Bool {
        if sector[0] != 0 || sector[11] != 0 { return false }
        for i in 1...10 where sector[i] != 0xFF { return false }
        return true
    }

    static func userDataOffset(sector: UnsafePointer<UInt8>, track: CueTrack) throws -> Int {
        switch track.sectorSize {
        case 2048:
            return 0
        case 2336:
            return 8
        case 2352, 2448:
            let synced = isSynced(sector)
            if synced && sector[15] == 2 { return 24 }
            if synced && sector[15] == 1 { return 16 }
            return track.mode.hasPrefix("MODE1") ? 16 : 24
        default:
            throw CueError(message: L("対応していないセクタの大きさです: \(track.mode)",
                                      "Unsupported sector size: \(track.mode)"))
        }
    }

    static func inspect(_ track: CueTrack, cancel: CancelFlag) -> TrackReport? {
        guard !track.isAudio, track.sectorSize != 2048,
              let handle = try? FileHandle(forReadingFrom: track.file),
              (try? handle.seek(toOffset: track.start)) != nil else { return nil }
        defer { try? handle.close() }
        let size = track.sectorSize
        var remaining = track.length / UInt64(size) * UInt64(size)
        var report = TrackReport()
        while remaining > 0 {
            if cancel.isCancelled { return nil }
            let want = Int(min(remaining, UInt64(size * chunkSectors)))
            guard let chunk = try? handle.read(upToCount: want), chunk.count == want else { return nil }
            chunk.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!
                for s in 0..<(want / size) {
                    examine(sector: p + s * size, track: track, index: report.sectors + UInt64(s), report: &report)
                }
            }
            report.sectors += UInt64(want / size)
            remaining -= UInt64(want)
        }
        return report
    }

    static func userData(_ track: CueTrack, sector: Int, handle: FileHandle) -> [UInt8]? {
        let size = track.sectorSize
        guard !track.isAudio, sector >= 0, UInt64(sector) < track.length / UInt64(size),
              (try? handle.seek(toOffset: track.start + UInt64(sector) * UInt64(size))) != nil,
              let data = try? handle.read(upToCount: size), data.count == size else { return nil }
        return data.withUnsafeBytes { raw -> [UInt8]? in
            let p = raw.bindMemory(to: UInt8.self).baseAddress!
            guard let offset = try? userDataOffset(sector: p, track: track), offset + 2048 <= size else { return nil }
            return Array(UnsafeBufferPointer(start: p + offset, count: 2048))
        }
    }

    private static func primaryDescriptor(_ track: CueTrack, handle: FileHandle) -> [UInt8]? {
        guard let d = userData(track, sector: 16, handle: handle), d[0] == 1, Array(d[1...5]) == Array("CD001".utf8) else {
            return nil
        }
        return d
    }

    private static func le32(_ d: [UInt8], _ at: Int) -> Int {
        Int(d[at]) | Int(d[at + 1]) << 8 | Int(d[at + 2]) << 16 | Int(d[at + 3]) << 24
    }

    private static func bytes(_ track: CueTrack, at offset: Int, count: Int, handle: FileHandle) -> [UInt8]? {
        var out: [UInt8] = []
        var position = offset
        while out.count < count {
            guard let d = userData(track, sector: position / 2048, handle: handle) else { return nil }
            let from = position % 2048
            let take = min(2048 - from, count - out.count)
            out += d[from..<(from + take)]
            position += take
        }
        return out
    }

    private static func macString(_ raw: [UInt8]) -> String {
        let data = Data(raw)
        if raw.contains(where: { $0 >= 0x80 }) {
            let japanese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.macJapanese.rawValue)))
            if let text = String(data: data, encoding: japanese) { return text }
        }
        return String(data: data, encoding: .macOSRoman) ?? ""
    }

    static func volume(_ track: CueTrack, pad: UInt64 = 0) -> VolumeInfo? {
        guard !track.isAudio, let handle = try? FileHandle(forReadingFrom: track.file) else { return nil }
        defer { try? handle.close() }
        var info = VolumeInfo()
        var root = 0
        for sector in 16..<48 {
            guard let d = userData(track, sector: sector, handle: handle) else { break }
            let id = String(decoding: d[1...5], as: UTF8.self)
            if id == "CD001" {
                if d[0] == 1 && !info.iso {
                    info.iso = true
                    let name = Data(d[40..<72])
                    info.label = (String(data: name, encoding: .shiftJIS) ?? String(decoding: name, as: UTF8.self))
                        .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0")))
                    let block = Int(d[128]) | Int(d[129]) << 8
                    if block > 0 { info.sectors = UInt64((le32(d, 80) * block + 2047) / 2048) }
                    root = le32(d, 158)
                } else if d[0] == 2, d[88] == 0x25, d[89] == 0x2F, [0x40, 0x43, 0x45].contains(d[90]) {
                    info.joliet = true
                } else if d[0] == 0, String(decoding: d[7..<30], as: UTF8.self) == "EL TORITO SPECIFICATION" {
                    info.elTorito = true
                }
            } else if id == "NSR02" || id == "NSR03" {
                info.udf = true
            } else if sector == 16, String(decoding: d[9..<14], as: UTF8.self) == "CDROM" {
                info.highSierra = true
            }
        }
        if info.iso, let r = userData(track, sector: root - Int(pad), handle: handle), r[0] >= 34 {
            let use = Array(r[34..<min(Int(r[0]), 2048)])
            let magic: [UInt8] = [0x53, 0x50, 0x07, 0x01, 0xBE, 0xEF]
            if use.count >= 6 {
                for i in 0...(use.count - 6) where Array(use[i..<(i + 6)]) == magic { info.rockRidge = true }
            }
        }
        func hfs(at offset: Int) -> Bool {
            guard let m = bytes(track, at: offset + 1024, count: 64, handle: handle) else { return false }
            if m[0] == 0x42 && m[1] == 0x44 {
                info.hfs = "HFS"
                let length = min(Int(m[36]), 27)
                if info.label.isEmpty { info.label = macString(Array(m[37..<(37 + length)])) }
                return true
            }
            if m[0] == 0x48 && (m[1] == 0x2B || m[1] == 0x58) {
                info.hfs = "HFS+"
                return true
            }
            return false
        }
        if let head = bytes(track, at: 0, count: 4, handle: handle) {
            if head[0] == 0x45 && head[1] == 0x52 {
                let declared = Int(head[2]) << 8 | Int(head[3])
                for block in [declared, 512, 2048] where block > 0 && info.hfs.isEmpty {
                    for entry in 1...16 {
                        guard let e = bytes(track, at: entry * block, count: 80, handle: handle), e[0] == 0x50, e[1] == 0x4D else { break }
                        let start = Int(e[8]) << 24 | Int(e[9]) << 16 | Int(e[10]) << 8 | Int(e[11])
                        let type = String(decoding: e[48..<80].prefix { $0 != 0 }, as: UTF8.self)
                        if type.hasPrefix("Apple_HFS"), hfs(at: start * block) { break }
                    }
                }
                if info.hfs.isEmpty { info.hfs = L("Apple パーティションマップ", "Apple Partition Map") }
            } else {
                _ = hfs(at: 0)
            }
        }
        return info.description == nil ? nil : info
    }

    static func alignment(_ track: CueTrack) -> Alignment {
        guard !track.isAudio, let handle = try? FileHandle(forReadingFrom: track.file) else { return Alignment() }
        defer { try? handle.close() }
        guard let d = primaryDescriptor(track, handle: handle) else { return Alignment() }
        let root = le32(d, 158)
        func isRoot(_ sector: Int) -> Bool {
            guard let r = userData(track, sector: sector, handle: handle) else { return false }
            return r[0] >= 34 && le32(r, 2) == root && r[25] & 2 != 0 && r[32] == 1 && r[33] == 0
        }
        if isRoot(root) { return Alignment(volume: true) }
        if track.lba > 0, isRoot(root - track.lba) { return Alignment(pad: UInt64(track.lba), volume: true) }
        let sectors = Int(min(track.length / UInt64(track.sectorSize), 4096))
        if sectors > 17 {
            for sector in 17..<sectors where sector < root && isRoot(sector) {
                return Alignment(pad: UInt64(root - sector), volume: true, fromScan: true)
            }
        }
        return Alignment(unverified: track.lba > 0)
    }

    private static func descriptors(_ track: CueTrack, handle: FileHandle) -> [UInt8] {
        var out: [UInt8] = []
        var sector = 16
        while sector < 80, let d = userData(track, sector: sector, handle: handle),
              Array(d[1...5]) == Array("CD001".utf8) {
            out += d
            sector += 1
            if d[0] == 255 { break }
        }
        return out
    }

    private static func relocated(_ parts: [ConvertJob]) -> [UInt8]? {
        guard let last = parts.last, last.pad > 0, let handle = try? FileHandle(forReadingFrom: last.track.file) else { return nil }
        defer { try? handle.close() }
        let found = descriptors(last.track, handle: handle)
        if found.isEmpty { return nil }
        for sector in 16..<(16 + found.count / 2048) {
            for part in parts where UInt64(sector) >= part.pad && UInt64(sector) < part.pad + part.track.sectors {
                if part.track.number == last.track.number { return nil }
                guard let other = try? FileHandle(forReadingFrom: part.track.file) else { return nil }
                defer { try? other.close() }
                guard let d = userData(part.track, sector: sector - Int(part.pad), handle: other) else { return nil }
                if Array(d[1...5]) != Array("CD001".utf8) && d.contains(where: { $0 != 0 }) { return nil }
            }
        }
        return found
    }

    static func canMerge(_ sheet: CueSheet, _ alignments: [Int: Alignment]) -> Bool {
        let tracks = sheet.tracks.filter { !$0.isAudio }
        guard tracks.count >= 2 else { return false }
        var parts: [ConvertJob] = []
        var end: UInt64 = 0
        for track in tracks {
            guard let alignment = alignments[track.number], alignment.volume, alignment.pad >= end else { return false }
            parts.append(ConvertJob(track: track, output: track.file, pad: alignment.pad))
            end = alignment.pad + track.sectors
        }
        return relocated(parts) != nil
    }

    private static func identity(_ path: String) -> [UInt64]? {
        var info = stat()
        return stat(path, &info) == 0 ? [UInt64(info.st_dev), UInt64(info.st_ino)] : nil
    }

    static func partial(_ output: URL) -> URL {
        output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".part")
    }

    @discardableResult
    static func run(_ jobs: [ConvertJob], cancel: CancelFlag,
                    progress: @escaping (Double, String) -> Void) throws -> [Int: TrackReport] {
        let parts = jobs.flatMap { $0.parts }
        let total = max(1, parts.reduce(UInt64(0)) { $0 + $1.track.length })
        var done: UInt64 = 0
        var reports: [Int: TrackReport] = [:]
        let inputs = Set(parts.map { $0.track.file.path }).compactMap(identity)
        for job in jobs where [job.output, partial(job.output)].contains(where: { url in
            identity(url.path).map { id in inputs.contains { $0 == id } } ?? false
        }) {
            throw CueError(message: L("出力が入力のファイルと同じ名前になります。保存先を変えてください: \(job.output.lastPathComponent)",
                                      "An output would overwrite an input file. Choose another folder: \(job.output.lastPathComponent)"))
        }
        for job in jobs {
            let name = job.output.lastPathComponent
            let temporary = partial(job.output)
            do {
                let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd < 0 {
                    throw CueError(message: L("書き出せません: \(job.output.path) (\(String(cString: strerror(errno))))",
                                              "Cannot write: \(job.output.path) (\(String(cString: strerror(errno))))"))
                }
                let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    defer { try? output.close() }
                    for part in job.parts {
                        reports[part.track.number] = try copy(part, to: output, cancel: cancel) { bytes in
                            done += bytes
                            progress(Double(done) / Double(total), name)
                        }
                    }
                    if let found = relocated(job.parts) {
                        try output.seek(toOffset: 16 * 2048)
                        try output.write(contentsOf: Data(found))
                    }
                    try output.synchronize()
                }
                if rename(temporary.path, job.output.path) != 0 {
                    throw CueError(message: L("書き出せません: \(job.output.path) (\(String(cString: strerror(errno))))",
                                              "Cannot write: \(job.output.path) (\(String(cString: strerror(errno))))"))
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        }
        progress(1, "")
        return reports
    }

    private static func copy(_ job: ConvertJob, to output: FileHandle, cancel: CancelFlag,
                             advance: (UInt64) -> Void) throws -> TrackReport {
        let track = job.track
        let input = try FileHandle(forReadingFrom: track.file)
        defer { try? input.close() }
        try input.seek(toOffset: track.start)
        let size = track.sectorSize
        let unit = track.isAudio ? 2352 : 2048
        var remaining = track.length / UInt64(size) * UInt64(size)
        var report = TrackReport()
        if track.isAudio {
            if size < 2352 {
                throw CueError(message: L("対応していないセクタの大きさです: \(track.mode)", "Unsupported sector size: \(track.mode)"))
            }
            if remaining > 4_000_000_000 {
                throw CueError(message: L("トラックが大きすぎて WAV にできません: \(track.file.lastPathComponent)",
                                          "The track is too large for a WAV file: \(track.file.lastPathComponent)"))
            }
            try output.write(contentsOf: wavHeader(dataBytes: remaining / UInt64(size) * 2352))
        }
        let swap = track.isAudio && track.fileType == "MOTOROLA"
        if job.pad > 0 { try output.seek(toOffset: job.pad * 2048) }

        while remaining > 0 {
            if cancel.isCancelled { throw Cancelled() }
            let want = Int(min(remaining, UInt64(size * chunkSectors)))
            guard let chunk = try input.read(upToCount: want), chunk.count == want else {
                throw CueError(message: L("bin ファイルが途中で終わっています: \(track.file.lastPathComponent)",
                                          "Unexpected end of bin file: \(track.file.lastPathComponent)"))
            }
            let count = want / size
            var out: Data
            if size == unit {
                out = chunk
            } else {
                out = Data(count: count * unit)
                try chunk.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: UInt8.self).baseAddress!
                    try out.withUnsafeMutableBytes { dstRaw in
                        let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                        for s in 0..<count {
                            let sector = src + s * size
                            var offset = 0
                            if !track.isAudio {
                                offset = try userDataOffset(sector: sector, track: track)
                                examine(sector: sector, track: track, index: report.sectors + UInt64(s), report: &report)
                            }
                            (dst + s * unit).update(from: sector + offset, count: unit)
                        }
                    }
                }
            }
            if swap {
                out.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self)
                    var i = 0
                    while i + 1 < p.count { p.swapAt(i, i + 1); i += 2 }
                }
            }
            try output.write(contentsOf: out)
            report.sectors += UInt64(count)
            remaining -= UInt64(want)
            advance(UInt64(want))
        }
        return report
    }

    private static func wavHeader(dataBytes: UInt64) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(dataBytes + 36))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16)
        u16(1); u16(2); u32(44100); u32(176400); u16(4); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataBytes))
        return d
    }
}

func runCLI(_ args: [String]) -> Int32 {
    let flags = args.filter { $0.hasPrefix("--") }
    let paths = args.filter { !$0.hasPrefix("--") }
    let cue = URL(fileURLWithPath: paths[0])
    let dir = paths.count > 1 ? URL(fileURLWithPath: paths[1]) : cue.deletingLastPathComponent()
    func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    if let unknown = flags.first(where: { !["--no-iso", "--no-wav", "--no-align", "--force"].contains($0) }) {
        note(L("知らないオプションです: \(unknown)", "Unknown option: \(unknown)"))
        return 1
    }
    do {
        let sheet = try CueSheet.load(cue)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let align = !flags.contains("--no-align")
        var alignments: [Int: Alignment] = [:]
        var volumes: [Int: VolumeInfo] = [:]
        for track in sheet.tracks where !track.isAudio {
            let alignment = Converter.alignment(track)
            alignments[track.number] = alignment
            volumes[track.number] = Converter.volume(track, pad: alignment.pad)
        }
        let merge = align && Converter.canMerge(sheet, alignments)
        let planned = Converter.plan(sheet, to: dir, iso: !flags.contains("--no-iso"), wav: !flags.contains("--no-wav"),
                                     alignments: align ? alignments : [:], merge: merge)
        let existing = planned.filter { FileManager.default.fileExists(atPath: $0.output.path) }
        if !existing.isEmpty && !flags.contains("--force") {
            let names = existing.map { $0.output.lastPathComponent }.joined(separator: ", ")
            note(L("同じ名前のファイルがあります。上書きするには --force を付けてください: \(names)",
                   "Some output files already exist. Pass --force to overwrite them: \(names)"))
            return 1
        }
        let jobs = planned.flatMap { $0.parts }
        for text in Converter.discNotes(sheet) { note("note: " + text) }
        for job in jobs {
            for text in Converter.info(job.track, alignments[job.track.number], align: align, merge: merge) {
                note(String(format: "note: Track %02d: ", job.track.number) + text)
            }
        }
        for job in jobs {
            var kind = job.track.mode
            if !job.track.isAudio {
                kind += " [" + (volumes[job.track.number]?.description ?? L("ファイルシステム不明", "unknown filesystem")) + "]"
            }
            print(String(format: "Track %02d %@ %llu bytes -> %@", job.track.number, kind,
                         job.track.length, job.output.lastPathComponent))
        }
        let reports = try Converter.run(planned, cancel: CancelFlag()) { _, _ in }
        for job in jobs {
            for text in Converter.warnings(job.track, reports[job.track.number], alignments[job.track.number],
                                           volumes[job.track.number]) {
                note(String(format: "warning: Track %02d: ", job.track.number) + text)
            }
        }
        return 0
    } catch {
        note(error.localizedDescription)
        return 1
    }
}
