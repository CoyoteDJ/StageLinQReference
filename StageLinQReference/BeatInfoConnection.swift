import Foundation
import Network
final class BeatInfoConnection {
    private var connection: NWConnection?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "StageLinQReference.beatinfo")
    var onState: ((String) -> Void)?
    var onBeat: ((Int, Double, Double, Double, String) -> Void)?
    func connect(_ device: PlayerDevice, localIdentity: Data) {
        guard let port = device.services["BeatInfo"] else { return }
        let c = NWConnection(host: .init(device.ip), port: .init(rawValue: UInt16(port))!, using: .tcp); connection = c; onState?("connecting")
        c.stateUpdateHandler = { [weak self] state in switch state { case .ready: self?.onState?("connected"); let localPort: Int = { if case let .hostPort(_, p) = c.currentPath?.localEndpoint { return Int(p.rawValue) }; return 0 }(); self?.sendHandshake(localIdentity, port: localPort); self?.sendStart(); self?.receive(c); case .failed(let e): self?.onState?("failed: \(e.localizedDescription)"); default: break } }; c.start(queue: queue)
    }
    private func sendHandshake(_ localIdentity: Data, port: Int) { var h=Data([0,0,0,0]); h.append(localIdentity.prefix(16)); h.appendString("BeatInfo"); h.appendU16(port); connection?.send(content:h,completion:.contentProcessed{_ in}) }
    private func sendStart() { var d=Data(); d.appendU32(4); d.appendU32(0); connection?.send(content:d,completion:.contentProcessed{_ in}) }
    private func receive(_ c:NWConnection) { c.receive(minimumIncompleteLength:1,maximumLength:65536){[weak self] data,_,complete,error in guard let self else{return}; self.queue.async { if let data { self.buffer.append(data); self.parse() }; if error != nil || complete { self.onState?("closed") } else { self.receive(c) } } } }
    private func parse() { while buffer.count >= 4 { guard let raw=buffer.u32(0), raw > 0, raw <= 1_048_576 else { buffer.removeFirst(1); continue }; let n=Int(raw); guard n >= 40, buffer.count >= n+4 else{return}; let b=Data(buffer.dropFirst(4).prefix(n)); buffer.removeFirst(n+4); let count=Int(b.u32(12) ?? 1); guard count > 0, count <= 8 else { continue }; for player in 0..<count { let base=16 + player * 24; guard base + 24 <= b.count else { break }; let beat=b.f64(base), total=b.f64(base + 8), bpm=b.f64(base + 16); if bpm > 0 || beat > 0 || total > 0 { onBeat?(player,beat,total,bpm,b.map{String(format:"%02X",$0)}.joined()) } } } }
}
private extension Data { func u32(_ i:Int)->UInt32?{guard i >= 0, i + 4 <= count else{return nil}; let b=Array(self); return UInt32(b[i])<<24|UInt32(b[i+1])<<16|UInt32(b[i+2])<<8|UInt32(b[i+3])}; func f64(_ i:Int)->Double{guard i >= 0, i + 8 <= count else{return 0}; return Double(bitPattern:stride(from:i,to:i+8,by:1).reduce(UInt64(0)){($0<<8)|UInt64(self[$1])})}; mutating func appendU16(_ n:Int){append(UInt8(truncatingIfNeeded: n >> 8));append(UInt8(truncatingIfNeeded: n))}; mutating func appendU32(_ n:Int){append(UInt8(truncatingIfNeeded: n >> 24));append(UInt8(truncatingIfNeeded: n >> 16));append(UInt8(truncatingIfNeeded: n >> 8));append(UInt8(truncatingIfNeeded: n))}; mutating func appendString(_ s:String){let b=Array(s.utf16).flatMap{[UInt8(truncatingIfNeeded: $0 >> 8),UInt8(truncatingIfNeeded: $0)]};appendU32(b.count);append(contentsOf:b)} }
