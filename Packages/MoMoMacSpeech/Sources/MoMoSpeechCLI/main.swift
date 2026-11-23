import Foundation
import MoMoMacSpeech

@main
struct MoMoSpeechCLI {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            printUsage()
            exit(1)
        }
        do {
            switch cmd {
            case "health":
                let modelsDir = argValue(args, flag: "--models-dir").map(URL.init(fileURLWithPath:))
                    ?? CoreMLBundleManager.defaultModelsRoot
                let mgr = CoreMLBundleManager(modelsRoot: modelsDir, idleEvictionSeconds: 0)
                try printJSON(mgr.status())

            case "vad":
                guard let path = argValue(args, flag: "--audio") else {
                    throw SpeechEngineError.invalidRequest("Missing --audio")
                }
                let modelsDir = argValue(args, flag: "--models-dir").map(URL.init(fileURLWithPath:))
                    ?? CoreMLBundleManager.defaultModelsRoot
                let mgr = CoreMLBundleManager(modelsRoot: modelsDir, idleEvictionSeconds: 0)
                let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: path))
                let res = mgr.getVAD().detectSpeech(samples: decoded.samples)
                try printJSON(res)

            case "embed":
                guard let path = argValue(args, flag: "--audio") else {
                    throw SpeechEngineError.invalidRequest("Missing --audio")
                }
                let modelsDir = argValue(args, flag: "--models-dir").map(URL.init(fileURLWithPath:))
                    ?? CoreMLBundleManager.defaultModelsRoot
                let mgr = CoreMLBundleManager(modelsRoot: modelsDir, idleEvictionSeconds: 0)
                let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: path))
                let enc = try mgr.getReDimNet()
                let res = try enc.extractEmbedding(samples: decoded.samples, vad: mgr.getVAD())
                try printJSON(res)

            case "transcribe":
                guard let path = argValue(args, flag: "--audio") else {
                    throw SpeechEngineError.invalidRequest("Missing --audio")
                }
                let modelsDir = argValue(args, flag: "--models-dir").map(URL.init(fileURLWithPath:))
                    ?? CoreMLBundleManager.defaultModelsRoot
                let hotwords = argValue(args, flag: "--hotwords")?
                    .split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) } ?? []
                let mgr = CoreMLBundleManager(modelsRoot: modelsDir, idleEvictionSeconds: 0)
                let decoded = try AudioDecoder.decodeFile(at: URL(fileURLWithPath: path))
                let moss = try mgr.getMOSS()
                let res = try moss.transcribe(samples: decoded.samples, hotwords: hotwords)
                try printJSON(res)

            case "serve":
                let port = UInt16(argValue(args, flag: "--port") ?? "8892") ?? 8892
                let token = argValue(args, flag: "--token") ?? ProcessInfo.processInfo.environment["MOMO_SPEECH_TOKEN"] ?? ""
                let modelsDir = argValue(args, flag: "--models-dir").map(URL.init(fileURLWithPath:))
                    ?? CoreMLBundleManager.defaultModelsRoot
                let mgr = CoreMLBundleManager(modelsRoot: modelsDir)
                let server = MacSpeechHTTPServer(port: port, authToken: token, bundleManager: mgr)
                try server.start()
                fputs("MoMoMacSpeech HTTP server listening on 127.0.0.1:\(port)\n", stderr)
                dispatchMain()

            default:
                printUsage()
                exit(1)
            }
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func argValue(_ args: [String], flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    static func printJSON<T: Encodable>(_ val: T) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.keyEncodingStrategy = .convertToSnakeCase
        let data = try enc.encode(val)
        if let str = String(data: data, encoding: .utf8) {
            print(str)
        }
    }

    static func printUsage() {
        fputs("""
        Usage:
          momo-speech-cli health [--models-dir PATH]
          momo-speech-cli vad --audio PATH [--models-dir PATH]
          momo-speech-cli embed --audio PATH [--models-dir PATH]
          momo-speech-cli transcribe --audio PATH [--hotwords w1,w2] [--models-dir PATH]
          momo-speech-cli serve --port PORT [--token SECRET] [--models-dir PATH]
        \n
        """, stderr)
    }
}
