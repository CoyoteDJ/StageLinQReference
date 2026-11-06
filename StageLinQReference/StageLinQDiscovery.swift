import Foundation
import Network
import Darwin
struct Announcement { let identity: String; let token: String; let role: String; let name: String; let ip: String; let directoryPort: Int }
struct DiscoveryFrame { let identity: String; let deviceName: String; let connectionType: String; let softwareName: String; let softwareVersion: String; let servicePort: Int }

enum DiscoveryCodec {
    static let magic = Data("airD".utf8)
    static func encode(identity: Data, deviceName: String, connectionType: String = "DISCOVERER_HOWDY_", softwareName: String = "StageLinQReference", softwareVersion: String = "0.1", servicePort: Int) -> Data {
        var d = magic; d.append(identity.prefix(16)); for s in [deviceName, connectionType, softwareName, softwareVersion] { appendNetworkString(s, to: &d) }; appendUInt16(servicePort, to: &d); return d
    }
    static func decode(_ data: Data, from ip: String) -> DiscoveryFrame? {
        var r = Reader(data); guard r.bytes(4) == magic, let id=r.bytes(16), let name=r.networkString(), let type=r.networkString(), let software=r.networkString(), let version=r.networkString(), let port=r.uint16() else { return nil }
        return DiscoveryFrame(identity:id.map{$0.hex}.joined(), deviceName:name, connectionType:type, softwareName:software, softwareVersion:version, servicePort:port)
    }
    private static func appendUInt16(_ n: Int, to d: inout Data) { d.append(UInt8((n >> 8) & 255)); d.append(UInt8(n & 255)) }
    private static func appendUInt32(_ n: Int, to d: inout Data) { d.append(UInt8((n >> 24) & 255)); d.append(UInt8((n >> 16) & 255)); d.append(UInt8((n >> 8) & 255)); d.append(UInt8(n & 255)) }
    private static func appendNetworkString(_ s: String, to d: inout Data) { let bytes=Array(s.utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }; appendUInt32(bytes.count, to:&d); d.append(contentsOf:bytes) }
    private struct Reader {
        var data: Data; var index = 0
        init(_ d: Data) { data = d }
        mutating func bytes(_ n: Int) -> Data? {
            guard n >= 0, index >= 0, index <= data.count, n <= data.count - index else { return nil }
            let (end, overflow) = index.addingReportingOverflow(n)
            guard !overflow else { return nil }
            let result = Data(data.dropFirst(index).prefix(n))
            guard result.count == n else { return nil }
            index = end; return result
        }
        mutating func uint16() -> Int? { guard let a = bytes(2), a.count == 2 else { return nil }; return Int(a[a.startIndex]) << 8 | Int(a[a.startIndex + 1]) }
        mutating func uint32() -> Int? { guard let a = bytes(4), a.count == 4 else { return nil }; let value = UInt32(a[a.startIndex]) << 24 | UInt32(a[a.startIndex + 1]) << 16 | UInt32(a[a.startIndex + 2]) << 8 | UInt32(a[a.startIndex + 3]); return Int(value) }
        mutating func networkString() -> String? { guard let n = uint32(), n <= data.count - index, n % 2 == 0, let b = bytes(n) else { return nil }; var units = [UInt16](); units.reserveCapacity(n / 2); for i in stride(from: 0, to: n, by: 2) { units.append(UInt16(b[b.startIndex + i]) << 8 | UInt16(b[b.startIndex + i + 1])) }; return String(decoding: units, as: Unicode.UTF16.self) }
    }
}
private extension UInt8 { var hex: String { String(format: "%02X", self) } }
enum DiscoveryParser {
    static func parse(_ data: Data, from ip: String) -> Announcement? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { p -> (String,String)? in let x = p.split(separator: "=", maxSplits: 1); return x.count == 2 ? (String(x[0]),String(x[1])) : nil })
        guard let identity=fields["identity"], let token=fields["token"], let role=fields["role"], let name=fields["name"], let port=Int(fields["directoryPort"] ?? "") else { return nil }
        return Announcement(identity: identity, token: token, role: role, name: name, ip: ip, directoryPort: port)
    }
}
final class StageLinQDiscovery {
    let announcementPort = 51337
    let identity: Data
    init() {
        // Use a stable low-order identity for this isolated reference
        // verifier so it can legitimately initiate the player relationships.
        // It is persisted and is never derived from an IP, model, or port.
        let key = "StageLinQReference.deviceIdentity.v4"
        if let saved = UserDefaults.standard.data(forKey: key), saved.count == 16 {
            identity = saved
        } else {
            // Retain the known-good reference identity used by the previous
            // live sessions. It is stable and independent of IP/model/port.
            let created = Data(repeating: 0, count: 15) + Data([1])
            UserDefaults.standard.set(created, forKey: key)
            identity = created
        }
    }
    private var udp: NWListener?
    private var tcp: NWListener?
    private var advertisedPort: Int = 0
    private var announceTimer: DispatchSourceTimer?
    private var udpFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    func stop() { announceTimer?.cancel(); announceTimer=nil; readSource?.cancel(); readSource=nil; if udpFD >= 0 { close(udpFD); udpFD = -1 }; tcp?.cancel(); tcp=nil; udp?.cancel(); udp=nil }
    func start(listenPort: Int = 51337, onFrame: @escaping (Data, String) -> Void, onTrace: @escaping (String, Int, String, String) -> Void, onStatus: @escaping (String) -> Void) {
        guard udp == nil else { return }
        do {
            let tcpListener = try NWListener(using: .tcp, on: .any)
            tcp = tcpListener
            tcpListener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let p = tcpListener.port { self?.advertisedPort = Int(p.rawValue); onStatus("TCP directory listener ready on port \(p.rawValue).") }
            }
            tcpListener.newConnectionHandler = { connection in connection.cancel() }
            tcpListener.start(queue: .global(qos: .userInitiated))
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP); guard fd >= 0 else { throw NSError(domain:"StageLinQ",code:Int(errno),userInfo:[NSLocalizedDescriptionKey:String(cString:strerror(errno))]) }
            var reuse:Int32=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&reuse,socklen_t(MemoryLayout<Int32>.size)); var broadcast:Int32=1; setsockopt(fd,SOL_SOCKET,SO_BROADCAST,&broadcast,socklen_t(MemoryLayout<Int32>.size))
            var address=sockaddr_in(); address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family=sa_family_t(AF_INET); address.sin_port=in_port_t(listenPort).bigEndian; address.sin_addr=in_addr(s_addr:in_addr_t(0));
            let bound=withUnsafePointer(to:&address){$0.withMemoryRebound(to:sockaddr.self,capacity:1){bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}; guard bound==0 else { close(fd); throw NSError(domain:"StageLinQ",code:Int(errno),userInfo:[NSLocalizedDescriptionKey:"UDP 51337 bind failed: \(String(cString:strerror(errno)))"]) }
            let interfaceIndex=if_nametoindex("en0"); if interfaceIndex > 0 { var index=interfaceIndex; setsockopt(fd,IPPROTO_IP,IP_BOUND_IF,&index,socklen_t(MemoryLayout<UInt32>.size)) }; _ = fcntl(fd, F_SETFL, O_NONBLOCK); udpFD=fd; let source=DispatchSource.makeReadSource(fileDescriptor:fd,queue:.global(qos:.userInitiated)); source.setEventHandler{ [weak self] in guard let self else{return}; var bytes=[UInt8](repeating:0,count:65535); var from=sockaddr_in(); var length=socklen_t(MemoryLayout<sockaddr_in>.size); let n=withUnsafeMutablePointer(to:&from){$0.withMemoryRebound(to:sockaddr.self,capacity:1){recvfrom(fd,&bytes,bytes.count,0,$0,&length)}}; guard n>0 else{return}; var hostBuffer=[CChar](repeating:0,count:Int(INET_ADDRSTRLEN)); var ip=from.sin_addr; inet_ntop(AF_INET,&ip,&hostBuffer, socklen_t(hostBuffer.count)); var payload=Data(bytes.prefix(n)); var sourceIP=String(cString:hostBuffer); if payload.count >= 8 && payload.prefix(4) == Data("SLPX".utf8) { let b=Array(payload[4..<8]); sourceIP="\(b[0]).\(b[1]).\(b[2]).\(b[3])"; payload.removeFirst(8) }; onFrame(payload,sourceIP) }; source.resume(); readSource=source; onStatus("UDP listener bound to en0 0.0.0.0:\(listenPort)")
        } catch { onStatus("Discovery start failed: \(error.localizedDescription)") }
    }
    func announce(target: String? = nil, onTrace: @escaping (Int, String, String) -> Void, onResult: @escaping (String) -> Void = { _ in }) {
        let packet = DiscoveryCodec.encode(identity: identity, deviceName: "StageLinQ Reference", servicePort: advertisedPort)
        let hex = packet.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
        func send(_ host: String) { guard udpFD >= 0 else { onResult("UDP send to \(host) failed: listener socket is not open"); return }; var destination=sockaddr_in(); destination.sin_len=UInt8(MemoryLayout<sockaddr_in>.size); destination.sin_family=sa_family_t(AF_INET); destination.sin_port=in_port_t(51337).bigEndian; host.withCString{inet_pton(AF_INET,$0,&destination.sin_addr)}; let sent=withUnsafePointer(to:&destination){ ptr in ptr.withMemoryRebound(to:sockaddr.self,capacity:1){ socketPtr in packet.withUnsafeBytes{ raw in sendto(udpFD,raw.baseAddress,packet.count,0,socketPtr,socklen_t(MemoryLayout<sockaddr_in>.size)) } } }; if sent==packet.count {onTrace(packet.count,hex,host);onResult("UDP sendto completed to \(host) from local port 51337")} else {onResult("UDP sendto to \(host) failed: \(String(cString:strerror(errno)))") } }
        send("10.0.0.255"); if let target { send(target) }
        if announceTimer == nil { let timer=DispatchSource.makeTimerSource(queue:.global(qos:.userInitiated)); timer.schedule(deadline:.now()+1, repeating:1); timer.setEventHandler { [weak self] in self?.announce(target:target,onTrace:onTrace,onResult:onResult) }; timer.resume(); announceTimer=timer }
    }
    func probe(mixerIP: String) -> Data { DiscoveryCodec.encode(identity: identity, deviceName: "StageLinQ Reference", servicePort: advertisedPort) }
}
