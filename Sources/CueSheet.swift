import Foundation

func L(_ ja: String, _ en: String) -> String {
    (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? ja : en
}

struct CueError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CueTrack: Identifiable {
    var number: Int
    var mode: String
    var file: URL
    var fileType: String
    var index0: Int?
    var index1: Int = 0
    var pregap = 0
    var postgap = 0
    var session = 1
    var gapBefore = 0
    var flags: Set<String> = []
    var lba = 0
    var start: UInt64 = 0
    var end: UInt64 = 0

    var id: Int { number }
    var isAudio: Bool { mode == "AUDIO" || mode == "CDG" }
    var length: UInt64 { end > start ? end - start : 0 }

    var sectorSize: Int {
        if mode == "CDG" { return 2448 }
        if isAudio { return 2352 }
        if let slash = mode.lastIndex(of: "/"), let n = Int(mode[mode.index(after: slash)...]) { return n }
        return 2352
    }

    var sectors: UInt64 { length / UInt64(sectorSize) }

    var duration: String {
        let frames = length / UInt64(sectorSize)
        return String(format: "%d:%02d", frames / 75 / 60, frames / 75 % 60)
    }
}

struct CueSheet {
    var url: URL
    var tracks: [CueTrack]

    var baseName: String { url.deletingPathExtension().lastPathComponent }

    static func load(_ url: URL) throws -> CueSheet {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .shiftJIS)
            ?? String(decoding: data, as: UTF8.self)
        let dir = url.deletingLastPathComponent()
        var tracks: [CueTrack] = []
        var file: URL?
        var fileType = "BINARY"
        var session = 1
        var pendingGap = 0

        func frames(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            guard parts.count == 3, parts.allSatisfy({ $0 >= 0 && $0 < 100_000 }) else { return nil }
            return (parts[0] * 60 + parts[1]) * 75 + parts[2]
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let command = words.first?.uppercased() else { continue }
            if command == "FILE" {
                var name: String
                if let a = line.firstIndex(of: "\""), let b = line.lastIndex(of: "\""), a < b {
                    name = String(line[line.index(after: a)..<b])
                } else if words.count >= 2 {
                    name = words[1]
                } else {
                    continue
                }
                fileType = words.count >= 3 ? words[words.count - 1].uppercased() : "BINARY"
                if fileType != "BINARY" && fileType != "MOTOROLA" {
                    throw CueError(message: L("この形式の FILE には対応していません (BINARY のみ): \(fileType)",
                                              "Unsupported FILE type (only BINARY is supported): \(fileType)"))
                }
                name = name.replacingOccurrences(of: "\\", with: "/")
                file = try resolve(name, in: dir)
            } else if command == "TRACK", words.count >= 3, let number = Int(words[1]) {
                guard let file else {
                    throw CueError(message: L("TRACK の前に FILE がありません", "TRACK appears before any FILE"))
                }
                var track = CueTrack(number: number, mode: words[2].uppercased(), file: file, fileType: fileType)
                if ![2048, 2336, 2352, 2448].contains(track.sectorSize) {
                    throw CueError(message: L("対応していないトラックの種類です: \(track.mode)", "Unsupported track type: \(track.mode)"))
                }
                track.session = session
                track.gapBefore = pendingGap
                pendingGap = 0
                tracks.append(track)
            } else if command == "INDEX", words.count >= 3, let number = Int(words[1]), !tracks.isEmpty {
                guard let value = frames(words[2]) else { continue }
                if number == 0 { tracks[tracks.count - 1].index0 = value }
                if number == 1 { tracks[tracks.count - 1].index1 = value }
            } else if command == "PREGAP", words.count >= 2, !tracks.isEmpty, let value = frames(words[1]) {
                tracks[tracks.count - 1].pregap = value
            } else if command == "POSTGAP", words.count >= 2, !tracks.isEmpty, let value = frames(words[1]) {
                tracks[tracks.count - 1].postgap = value
            } else if command == "FLAGS", !tracks.isEmpty {
                tracks[tracks.count - 1].flags = Set(words.dropFirst().map { $0.uppercased() })
            } else if command == "REM", words.count >= 3 {
                let key = words[1].uppercased()
                if key == "SESSION", let value = Int(words[2]) {
                    session = value
                } else if ["LEAD-OUT", "LEAD-IN", "PREGAP"].contains(key), let value = frames(words[2]) {
                    pendingGap += value
                }
            }
        }
        if tracks.isEmpty {
            throw CueError(message: L("トラックが見つかりません", "No tracks found in the cue sheet"))
        }
        try layout(&tracks)
        if let hidden = hiddenTrack(before: tracks[0]) { tracks.insert(hidden, at: 0) }
        return CueSheet(url: url, tracks: tracks)
    }

    private static func hiddenTrack(before first: CueTrack) -> CueTrack? {
        let size = first.sectorSize
        guard first.isAudio, first.number > 0, first.start >= UInt64(size), first.start <= first.end,
              let handle = try? FileHandle(forReadingFrom: first.file) else { return nil }
        defer { try? handle.close() }
        let high = first.fileType == "MOTOROLA" ? 0 : 1
        var remaining = first.start / UInt64(size) * UInt64(size)
        var audible = false
        while remaining > 0 && !audible {
            let want = Int(min(remaining, UInt64(size * 1024)))
            guard let chunk = try? handle.read(upToCount: want), chunk.count == want else { return nil }
            chunk.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                var sector = 0
                while sector < want && !audible {
                    var i = sector
                    while i < sector + 2352 {
                        let value = Int(Int16(bitPattern: UInt16(p[i + high]) << 8 | UInt16(p[i + 1 - high])))
                        if abs(value) > 64 { audible = true; break }
                        i += 2
                    }
                    sector += size
                }
            }
            remaining -= UInt64(want)
        }
        guard audible else { return nil }
        var hidden = CueTrack(number: 0, mode: first.mode, file: first.file, fileType: first.fileType)
        hidden.session = first.session
        hidden.end = first.start / UInt64(size) * UInt64(size)
        return hidden
    }

    static func find(referencing file: URL) -> URL? {
        let dir = file.deletingLastPathComponent()
        let target = file.standardizedFileURL.path
        let items = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        for item in items where item.lowercased().hasSuffix(".cue") {
            let cue = dir.appendingPathComponent(item)
            if let sheet = try? load(cue), sheet.tracks.contains(where: { $0.file.standardizedFileURL.path == target }) {
                return cue
            }
        }
        return nil
    }

    private static func resolve(_ name: String, in dir: URL) throws -> URL {
        let fm = FileManager.default
        let direct = URL(fileURLWithPath: name, relativeTo: dir).standardizedFileURL
        if fm.fileExists(atPath: direct.path) { return direct }
        let leaf = (name as NSString).lastPathComponent
        let items = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if let hit = items.first(where: { $0.compare(leaf, options: .caseInsensitive) == .orderedSame }) {
            return dir.appendingPathComponent(hit)
        }
        throw CueError(message: L("bin ファイルが見つかりません: \(leaf)", "Bin file not found: \(leaf)"))
    }

    private static func layout(_ tracks: inout [CueTrack]) throws {
        var i = 0
        var disc = 0
        var session = tracks[0].session
        var sessionChanges = 0
        while i < tracks.count {
            var j = i
            while j + 1 < tracks.count && tracks[j + 1].file == tracks[i].file { j += 1 }
            let attrs = try FileManager.default.attributesOfItem(atPath: tracks[i].file.path)
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            var firsts: [UInt64] = []
            var previousFrame = 0
            var previousOffset: UInt64 = 0
            var previousSize = 0
            for k in i...j {
                let frame = tracks[k].index0 ?? tracks[k].index1
                let size = tracks[k].sectorSize
                let offset: UInt64
                if k == i {
                    offset = UInt64(frame) * UInt64(size)
                } else {
                    offset = previousOffset + UInt64(max(0, frame - previousFrame)) * UInt64(previousSize)
                }
                firsts.append(offset)
                tracks[k].start = offset + UInt64(max(0, tracks[k].index1 - frame)) * UInt64(size)
                previousFrame = frame
                previousOffset = offset
                previousSize = size
            }
            for k in i...j {
                let next = k < j ? firsts[k - i + 1] : fileSize
                tracks[k].end = min(next, fileSize)
            }
            var inserted = 0
            for k in i...j {
                if tracks[k].session != session {
                    inserted += tracks[k].gapBefore > 0 ? tracks[k].gapBefore : (sessionChanges == 0 ? 11400 : 6900)
                    session = tracks[k].session
                    sessionChanges += 1
                }
                inserted += tracks[k].pregap
                tracks[k].lba = disc + inserted + tracks[k].index1
                inserted += tracks[k].postgap
            }
            let rest = fileSize > previousOffset ? Int((fileSize - previousOffset) / UInt64(previousSize)) : 0
            disc += previousFrame + rest + inserted
            i = j + 1
        }
    }
}
