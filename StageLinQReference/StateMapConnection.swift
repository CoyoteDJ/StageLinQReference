import Foundation
import Network

final class StateMapConnection {
    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "StageLinQReference.statemap")
    var onState: ((String) -> Void)?
    var onRecord: ((String, String, String) -> Void)?
    var onRaw: ((String) -> Void)?
    var onOutbound: ((String) -> Void)?

    func connect(_ device: PlayerDevice, localIdentity: Data) {
        guard let port = device.services["StateMap"] else { return }
        let c = NWConnection(host: .init(device.ip), port: .init(rawValue: UInt16(port))!, using: .tcp)
        connection = c
        onState?("connecting")
        c.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onState?("connected")
                let localPort: Int = { if case let .hostPort(_, p) = c.currentPath?.localEndpoint { return Int(p.rawValue) }; return 0 }()
                self?.sendHandshake(localIdentity, port: localPort) { [weak self] in
                    // Real devices expect the per-service identity frame to
                    // be processed before the first StateMap request.
                    self?.queue.asyncAfter(deadline: .now() + 0.1) { self?.subscribe() }
                // A few player firmware versions acknowledge the TCP
                // connection but ignore the first request batch while the
                // service relationship is settling. Retry the same locked
                // table once without rediscovery or port rotation.
                self?.queue.asyncAfter(deadline: .now() + 4.0) { self?.subscribe() }
                }
                self?.receive(c)
            case .failed(let error): self?.onState?("failed: \(error.localizedDescription)")
            default: break
            }
        }
        c.start(queue: queue)
    }

    private func sendHandshake(_ localIdentity: Data, port: Int, completion: @escaping () -> Void) { var h=Data([0,0,0,0]); h.append(localIdentity.prefix(16)); h.appendString("StateMap"); h.appendU16(port); connection?.send(content:h,completion:.contentProcessed{_ in completion()}) }
    private func subscribe() {
        var paths = [String]()
        let deckFields = [
            "Track/SongLoaded", "Track/SongAnalyzed", "Track/TrackName", "Track/TrackData",
            "Track/ArtistName", "Track/SampleRate", "Track/SongName", "Track/CurrentBPM",
            "Track/TrackLength", "PlayStatePath", "SpeedState", "ExternalMixerVolume",
            "CurrentBPM", "PlayState", "Play", "Speed", "TrackPosition", "KeyString",
            "SyncMode", "DeckIsMaster", "MasterTempo", "LoopEnableState", "CurrentLoopSizeInBeats"
        ]
        let mixerFields = [
            "/Mixer/CH1faderPosition", "/Mixer/CH2faderPosition",
            "/Mixer/CH3faderPosition", "/Mixer/CH4faderPosition",
            "/Mixer/CrossfaderPosition",
            "/Engine/Deck1/ExternalMixerVolume", "/Engine/Deck2/ExternalMixerVolume"
        ]
        for deck in [1, 2] {
            for field in deckFields {
                let path = field.hasPrefix("Track/") ? "/Engine/Deck\(deck)/\(field)" : (field == "ExternalMixerVolume" ? "/Engine/Deck\(deck)/\(field)" : "/Engine/Deck\(deck)/\(field)")
                paths.append(path)
            }
        }
        paths.append(contentsOf: mixerFields)
        // Some players accept the handshake but drop a burst of requests.
        // Pace subscriptions so every device has time to process them.
        for (index, path) in paths.enumerated() {
            queue.asyncAfter(deadline: .now() + 0.05 * Double(index)) { [weak self] in
                self?.sendSubscription(path)
            }
        }
    }
    private func sendSubscription(_ path: String) { var b=Data("smaa".utf8); b.appendU32(0x7d2); b.appendString(path); b.appendU32(0); var f=Data(); f.appendU32(UInt32(b.count)); f.append(b); onOutbound?("StateMap request \(path): \(f.map { String(format: "%02X", $0) }.joined())"); connection?.send(content:f,completion:.contentProcessed{_ in}) }

    private func receive(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.queue.async {
                if let data { self.buffer.append(data); self.onRaw?(data.map { String(format: "%02X", $0) }.joined()); self.parse() }
                if error != nil || complete { self.onState?("closed") } else { self.receive(c) }
            }
        }
    }

    private func parse() {
        while buffer.count >= 4 {
            guard let rawLength = buffer.u32(0), rawLength > 0, rawLength <= 1_048_576 else { buffer.removeFirst(1); continue }
            let length = Int(rawLength)
            guard buffer.count >= length + 4 else { return }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(length + 4)
            guard body.count >= 16, String(data: Data(body.prefix(4)), encoding: .ascii) == "smaa" else { continue }
            // smaa response body: magic(4), command(4), nameLength(4), name, valueLength(4), value.
            guard let rawNameLength = body.u32(8), rawNameLength <= 1_048_576 else { continue }
            let nameLength = Int(rawNameLength)
            guard body.count >= 12 + nameLength + 4 else { continue }
            let name = body.utf16String(at: 12, length: nameLength)
            // The value-length field follows the 4-byte name-length field
            // and the UTF-16 name bytes: 4 + 4 + 4 + nameLength.
            // The previous offset was four bytes too far, which caused every
            // valid device response to be discarded.
            guard let rawValueLength = body.u32(12 + nameLength), rawValueLength <= 1_048_576 || rawValueLength == UInt32.max else { continue }
            let valueLength = Int(rawValueLength)
            let value = rawValueLength == UInt32.max ? "unavailable" : (body.count >= 16 + nameLength + valueLength ? body.utf16String(at: 16 + nameLength, length: valueLength) : "unavailable")
            onRecord?(name, value, body.map { String(format: "%02X", $0) }.joined())
        }
    }
}

private extension Data {
    func u32(_ index: Int) -> UInt32? { guard index >= 0, index + 4 <= count else { return nil }; let bytes = Array(self); return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16 | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3]) }
    func utf16String(at index: Int, length: Int) -> String { String(decoding: stride(from: index, to: index + length, by: 2).map { UInt16(self[$0]) << 8 | UInt16(self[$0 + 1]) }, as: Unicode.UTF16.self) }
    mutating func appendU16(_ n:Int){append(UInt8(truncatingIfNeeded: n >> 8));append(UInt8(truncatingIfNeeded: n))}; mutating func appendU32(_ n:UInt32){append(UInt8(truncatingIfNeeded: n >> 24));append(UInt8(truncatingIfNeeded: n >> 16));append(UInt8(truncatingIfNeeded: n >> 8));append(UInt8(truncatingIfNeeded: n))}; mutating func appendString(_ s:String){let b=Array(s.utf16).flatMap{[UInt8(truncatingIfNeeded: $0 >> 8),UInt8(truncatingIfNeeded: $0)]};appendU32(UInt32(b.count));append(contentsOf:b)}
}
