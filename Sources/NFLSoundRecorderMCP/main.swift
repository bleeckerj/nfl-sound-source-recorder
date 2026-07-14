import Foundation
import AppKit
import SoundRecorderKit

// A minimal Model Context Protocol server: JSON-RPC 2.0 messages, one per line,
// on stdin/stdout. Logs go to stderr (stdout must stay pure protocol traffic).
// No external dependencies — just Foundation.

final class MCPServer {
    private let session = RecorderSession()
    private let out = FileHandle.standardOutput

    func run() {
        log("nfl-sound-recorder-mcp ready")
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            handle(line)
        }
    }

    // MARK: JSON-RPC plumbing

    private func handle(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log("Ignoring non-JSON line: \(line)")
            return
        }
        guard let method = message["method"] as? String else { return } // a response; ignore
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]
        let isRequest = id != nil

        switch method {
        case "initialize":
            let clientProtocol = params["protocolVersion"] as? String
            sendResult(id: id, result: [
                "protocolVersion": clientProtocol ?? "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "nfl-sound-recorder", "version": "0.1.0"],
            ])
        case "ping":
            sendResult(id: id, result: [String: Any]())
        case "tools/list":
            sendResult(id: id, result: ["tools": Self.toolDefinitions])
        case "resources/list":
            sendResult(id: id, result: ["resources": [Any]()])
        case "prompts/list":
            sendResult(id: id, result: ["prompts": [Any]()])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = callTool(name: name, arguments: args)
            sendResult(id: id, result: [
                "content": [["type": "text", "text": text]],
                "isError": isError,
            ])
        default:
            if isRequest { sendError(id: id, code: -32601, message: "Method not found: \(method)") }
        }
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        out.write(data)
        out.write(Data([0x0A]))
    }

    private func sendResult(id: Any?, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func sendError(id: Any?, code: Int, message: String) {
        send(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func log(_ text: String) {
        FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    }

    // MARK: Tools

    private func callTool(name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch name {
        case "list_applications":
            let apps = AudioProcesses.list().map {
                ["name": $0.name, "bundleId": $0.bundleID, "pid": Int($0.pid), "isPlaying": $0.isPlaying] as [String: Any]
            }
            return (Self.json(["applications": apps]), false)

        case "list_output_devices":
            do {
                let defaultID = try? AudioSystem.defaultOutputDevice()
                let devices = try AudioSystem.outputDevices().map {
                    ["name": $0.name, "uid": $0.uid, "channels": $0.outputChannels, "isDefault": $0.id == defaultID] as [String: Any]
                }
                return (Self.json(["outputDevices": devices]), false)
            } catch {
                return ("Error listing devices: \(error)", true)
            }

        case "list_input_devices":
            do {
                let defaultID = try? AudioSystem.defaultInputDevice()
                let devices = try AudioSystem.inputDevices().map {
                    ["name": $0.name, "uid": $0.uid, "channels": $0.inputChannels, "isDefault": $0.id == defaultID] as [String: Any]
                }
                return (Self.json(["inputDevices": devices]), false)
            } catch {
                return ("Error listing input devices: \(error)", true)
            }

        case "start_recording":
            return startRecording(arguments)

        case "set_equalizer":
            let enabled = arguments["enabled"] as? Bool
            let gains = (arguments["gains"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
            session.setEqualizer(enabled: enabled, gains: gains)
            return (Self.json([
                "equalizerEnabled": session.eqEnabled,
                "gains": session.eqGains,
                "centerFrequencies": GraphicEQ.centerFrequencies,
            ]), false)

        case "stop_recording":
            if let stopped = session.stop() {
                return (Self.json(["stopped": true, "file": stopped.url.path, "durationSeconds": Int(stopped.duration)]), false)
            }
            return ("Not currently recording.", true)

        case "recording_status":
            if let active = session.active {
                let elapsed = Int(Date().timeIntervalSince(active.startDate))
                return (Self.json([
                    "isRecording": true, "source": active.sourceLabel, "device": active.deviceName,
                    "file": active.fileURL.path, "elapsedSeconds": elapsed,
                    "framesCaptured": Int(active.recorder.meter.totalFrames),
                    "inputPeak": Double(active.recorder.meter.peak),
                    "equalizerEnabled": session.eqEnabled, "gains": session.eqGains,
                ]), false)
            }
            return (Self.json(["isRecording": false, "equalizerEnabled": session.eqEnabled, "gains": session.eqGains]), false)

        default:
            return ("Unknown tool: \(name)", true)
        }
    }

    private func startRecording(_ args: [String: Any]) -> (text: String, isError: Bool) {
        // Resolve the tap target (if any). `source: "microphone"` (or "none") records the
        // mic alone — no tap.
        var tapTarget: ProcessTapRecorder.Target?
        var tapLabel: String?
        let sourceArg = (args["source"] as? String)?.lowercased()
        if let pid = args["pid"] as? Int {
            tapTarget = .pid(pid_t(pid))
            tapLabel = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName ?? "pid \(pid)"
        } else if sourceArg == "microphone" || sourceArg == "mic" || sourceArg == "none" {
            tapTarget = nil
        } else {
            let source = sourceArg ?? "system"
            if source == "system" {
                tapTarget = .systemWide
                tapLabel = "All System Audio"
            } else if let app = AudioProcesses.bestMatch(bundleID: args["source"] as? String ?? source) {
                tapTarget = .pid(app.pid)
                tapLabel = app.name
            } else {
                return ("No audio-capable process with bundle id '\(source)'. Start playback, call list_applications again, or use source 'microphone' to record the mic.", true)
            }
        }

        // Resolve the microphone (if requested): "default" or an input device uid.
        var micDevice: AudioDeviceInfo?
        if let micArg = args["microphone"] as? String {
            let inputs: [AudioDeviceInfo]
            do { inputs = try AudioSystem.inputDevices() } catch { return ("Error listing input devices: \(error)", true) }
            if micArg.lowercased() == "default" {
                let defaultID = try? AudioSystem.defaultInputDevice()
                guard let match = inputs.first(where: { $0.id == defaultID }) ?? inputs.first else {
                    return ("No input devices available.", true)
                }
                micDevice = match
            } else {
                guard let match = inputs.first(where: { $0.uid == micArg }) else {
                    return ("No input device with uid '\(micArg)'. Call list_input_devices first.", true)
                }
                micDevice = match
            }
        }

        // Combine into a capture source.
        let captureSource: ProcessTapRecorder.Source
        let label: String
        switch (tapTarget, micDevice) {
        case let (.some(t), .some(m)): captureSource = .mix(tap: t, mic: m); label = "\(tapLabel ?? "tap") + mic (\(m.name))"
        case let (.some(t), .none):    captureSource = .tap(t); label = tapLabel ?? "tap"
        case let (.none, .some(m)):    captureSource = .microphone(m); label = "mic (\(m.name))"
        case (.none, .none):
            return ("No capture source. Provide a tap (source/pid) and/or a microphone.", true)
        }

        // Resolve the output device. `output_uid: "none"` records only (no routing).
        let device: AudioDeviceInfo?
        if (args["output_uid"] as? String)?.lowercased() == "none" {
            device = nil
        } else {
            let devices: [AudioDeviceInfo]
            do { devices = try AudioSystem.outputDevices() } catch { return ("Error listing devices: \(error)", true) }
            if let uid = args["output_uid"] as? String {
                guard let match = devices.first(where: { $0.uid == uid }) else {
                    return ("No output device with uid '\(uid)'. Call list_output_devices first.", true)
                }
                device = match
            } else {
                let defaultID = try? AudioSystem.defaultOutputDevice()
                guard let match = devices.first(where: { $0.id == defaultID }) ?? devices.first else {
                    return ("No output devices available. Pass output_uid 'none' to record only.", true)
                }
                device = match
            }
        }

        let mute = (args["mute"] as? Bool) ?? false
        let driftCompensation = (args["drift_compensation"] as? Bool) ?? false
        let warmupSeconds = (args["warmup_seconds"] as? Double) ?? 0.6
        let sourceLevelDB = (args["source_level_db"] as? NSNumber)?.doubleValue
        let micLevelDB = (args["mic_level_db"] as? NSNumber)?.doubleValue
        // Output codec: AAC (~1 MB/min) by default; an unknown value is a hard error so a
        // typo doesn't silently fall back to a huge lossless file.
        let format: RecordingFormat
        if let raw = args["format"] as? String {
            guard let f = RecordingFormat(rawValue: raw.lowercased()) else {
                let choices = RecordingFormat.allCases.map(\.rawValue).joined(separator: ", ")
                return ("Unknown format \"\(raw)\". Choose one of: \(choices).", true)
            }
            format = f
        } else {
            format = .aac
        }
        // Confined to the recordings directory — a client can choose a filename,
        // not an arbitrary path. The extension is forced to match the codec.
        let fileURL: URL = (args["file_path"] as? String).map {
            RecordingFiles.confinedURL(forRequestedPath: $0, format: format)
        } ?? RecordingFiles.newURL(format: format)

        do {
            try session.start(source: captureSource, sourceLabel: label, device: device, mute: mute,
                              driftCompensation: driftCompensation, warmupSeconds: warmupSeconds,
                              sourceLevelDB: sourceLevelDB, micLevelDB: micLevelDB,
                              format: format, fileURL: fileURL)
            return (Self.json([
                "started": true, "source": label, "device": device?.name ?? "(record only)", "mute": mute,
                "driftCompensation": driftCompensation, "format": format.rawValue, "file": fileURL.path,
            ]), false)
        } catch {
            return ("Failed to start recording: \(error)", true)
        }
    }

    // MARK: Tool schemas

    private static func stringProp(_ desc: String) -> [String: Any] { ["type": "string", "description": desc] }

    static var toolDefinitions: [[String: Any]] { [
        [
            "name": "list_applications",
            "description": "List audio-first applications currently known to the system. Each entry has name, bundleId, pid, and isPlaying (whether it is producing audio right now). Re-enumerated live on every call.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "list_output_devices",
            "description": "List available audio output devices to route to. Each entry has name, uid, channels, and isDefault. Re-enumerated live on every call.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "list_input_devices",
            "description": "List available audio input devices (microphones) that can be captured. Each entry has name, uid, channels, and isDefault. Re-enumerated live on every call.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "start_recording",
            "description": "Start capturing audio to a file while optionally routing it to an output device. Can capture a process/system tap, the microphone, or BOTH mixed together (source + microphone) into one file with independent per-feed levels.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "source": stringProp("'system' for all system audio, an application bundle id from list_applications, or 'microphone' to record the mic alone. Defaults to 'system'."),
                    "pid": ["type": "integer", "description": "Optional process id to capture, overriding 'source'."],
                    "microphone": stringProp("Also capture a microphone and MIX it in: 'default' for the default input, or an input device uid from list_input_devices. Combine with a tap source for system+mic; omit for tap-only."),
                    "source_level_db": ["type": "number", "description": "Tap/system feed level in dB (0 = unity). Use with mic_level_db to balance a mix."],
                    "mic_level_db": ["type": "number", "description": "Microphone feed level in dB (0 = unity). Use with source_level_db to balance a mix."],
                    "output_uid": stringProp("UID of the output device from list_output_devices, or 'none' to record only (no routing). Defaults to the current default output. Tip: with a microphone, prefer 'none' or headphones to avoid feedback."),
                    "mute": ["type": "boolean", "description": "If true, mute the source's normal output so only the routed copy is heard (reroute). Default false."],
                    "drift_compensation": ["type": "boolean", "description": "Resample the tap to the output clock. Default false; enabling can add a brief level ramp at the start."],
                    "warmup_seconds": ["type": "number", "description": "Hold off file-writing this long to skip Core Audio's device-start volume ramp. Default 0.6; use 0 to keep the raw ramp."],
                    "format": stringProp("Output codec: aac (default, ~1 MB/min, lossy), or lossless caf/wav/aiff/alac/flac (caf ~90 MB/min). macOS has no MP3 encoder — use aac."),
                    "file_path": stringProp("Optional filename for the recording. Only the filename is used (its extension is replaced to match the format); writes are confined to ~/Music/TapDeck/."),
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "set_equalizer",
            "description": "Enable/disable the 10-band graphic EQ and set per-band gains in dB. Bands are centered at 32, 64, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz (low to high). Applies live if recording, otherwise to the next recording. Gains clamp to ±24 dB.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "enabled": ["type": "boolean", "description": "Turn the EQ on or off."],
                    "gains": ["type": "array", "items": ["type": "number"], "description": "Up to 10 per-band gains in dB, low to high frequency."],
                ],
                "additionalProperties": false,
            ],
        ],
        [
            "name": "stop_recording",
            "description": "Stop the current recording and return the saved file path and duration.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
        [
            "name": "recording_status",
            "description": "Report whether a recording is in progress, and if so its source, device, file, and elapsed seconds.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
        ],
    ] }

    static func json(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

MCPServer().run()
