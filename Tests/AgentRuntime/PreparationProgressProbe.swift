import Foundation

@main struct PreparationProgressProbe {
    static func main() {
        var events = DesktopPreparationEvents()
        assert(events.append(Data("Downloading packages\nMOMO_PRE".utf8)).isEmpty)
        assert(events.append(Data("PARE agent\r\nMOMO_PREPARE connection\n".utf8)) == [.phase(.agent), .phase(.connection)])
        assert(events.append(Data("MOMO_PREPARE unknown\nMOMO_PREPARE rea".utf8)).isEmpty)
        assert(events.append(Data("dy\n".utf8)) == [.phase(.ready)])
        assert(events.append(Data(repeating: 65, count: 100_000)).isEmpty)
        assert(events.append(Data("MOMO_PREPARE agent\n".utf8)) == [.phase(.agent)])
        assert(events.append(Data("\u{001B}[2Kpackage-name  ----   1.00MiB/4.00MiB\r".utf8)) == [.download("package-name", 1048576, 4194304)])
        assert(events.append(Data("cpython (extracting) ---- 2MiB/4MiB\n".utf8)).isEmpty)
        var download = DesktopDownloadProgress()
        let start = Date(timeIntervalSince1970: 0)
        download.record(name: "a", received: 0, total: 4194304, now: start)
        download.record(name: "a", received: 1048576, total: 4194304, now: start.addingTimeInterval(1))
        assert(download.fraction == 0.25)
        assert(download.speed(at: start.addingTimeInterval(1)) == 1048576)
        assert(download.speed(at: start.addingTimeInterval(5)) == 0)
        download.record(name: "a", received: 0, total: 4194304, now: start.addingTimeInterval(6))
        assert(download.speed(at: start.addingTimeInterval(6)) == nil)
        if CommandLine.arguments.count > 1 {
            let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let metrics = events.append(raw).filter { if case .download = $0 { true } else { false } }
            assert(metrics.count > 2, "Real uv download must provide multiple byte samples")
        }
        print("PASS: fragmented events, ANSI byte counters, speed, stalls, retries, bounded buffer")
    }
}
