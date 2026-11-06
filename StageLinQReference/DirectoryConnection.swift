import Foundation
import Network

struct DirectoryServiceRecord { let deviceID: String; let name: String; let port: Int }
struct DirectoryStream {
    private(set) var buffer=Data()
    var keepalives=[Data]()
    mutating func append(_ data:Data)->[DirectoryServiceRecord] {
        buffer.append(data)
        var out=[DirectoryServiceRecord]()
        while true {
            let before = buffer.count
            if let record = parseOne() { out.append(record) }
            if buffer.count == before { break }
        }
        return out
    }
    private mutating func parseOne()->DirectoryServiceRecord? {
        guard buffer.count >= 4 else { return nil }
        let type = buffer.u32(0)
        if type == 2 {
            guard buffer.count >= 20 else { return nil }
            buffer.removeFirst(20)
            return DirectoryServiceRecord(deviceID:"", name:"DirectoryRequest", port:0)
        }
        if type == 1 {
            guard buffer.count >= 44 else { return nil }
            let bytes = Array(buffer)
            keepalives.append(Data(bytes[4..<44]))
            buffer.removeFirst(44)
            return nil
        }
        guard type == 0 else {
            buffer.removeFirst(1)
            return buffer.count >= 4 ? parseOne() : nil
        }
        guard buffer.count >= 24 else { return nil }
        let bytes = Array(buffer)
        guard bytes.count >= 24 else { return nil }
        let id = bytes[4..<20].map { String(format:"%02X", $0) }.joined()
        let byteCount = Int(buffer.u32(20))
        guard byteCount % 2 == 0, byteCount <= 1_048_576 else {
            buffer.removeFirst(4)
            return nil
        }
        let recordLength = 26 + byteCount
        guard recordLength >= 26, recordLength <= buffer.count else { return nil }
        let d = Array(bytes[24..<(24 + byteCount)])
        var units = [UInt16]()
        units.reserveCapacity(byteCount / 2)
        for i in stride(from: 0, to: byteCount, by: 2) {
            units.append(UInt16(d[i]) << 8 | UInt16(d[i + 1]))
        }
        let name = String(decoding: units, as: Unicode.UTF16.self)
        let port = Int(buffer.u16(24 + byteCount))
        buffer.removeFirst(recordLength)
        return DirectoryServiceRecord(deviceID:id, name:name, port:port)
    }
}
final class DirectoryConnection {
    private var connection:NWConnection?; private var stream=DirectoryStream()
    private let receiveQueue = DispatchQueue(label: "StageLinQReference.directory.receive")
    private var ourIdentity=Data()
    func connect(ip:String,port:Int,identity:Data,onState:@escaping(String)->Void,onServices:@escaping([DirectoryServiceRecord])->Void){ourIdentity=identity;let c=NWConnection(host:NWEndpoint.Host(ip),port:NWEndpoint.Port(rawValue:UInt16(port))!,using:.tcp);connection=c;onState("connecting");c.stateUpdateHandler={ [weak self] state in switch state {case .ready:
            onState("connected")
            // Arm the receive loop before requesting services.  Reference
            // implementations do this in that order so the request, its
            // request-ack, and all coalesced announcements are consumed by
            // one continuous stream decoder.
            self?.receive(c,onState:onState,onServices:onServices)
            var request=Data([0,0,0,2]);request.append(identity.prefix(16));
            c.send(content:request,completion:.contentProcessed{_ in})
            onState("services requested")
        case .failed(let e):onState("failed: \(e.localizedDescription)");default:break}};c.start(queue:.global(qos:.userInitiated))}
    private func receive(_ c:NWConnection,onState:@escaping(String)->Void,onServices:@escaping([DirectoryServiceRecord])->Void){c.receive(minimumIncompleteLength:1,maximumLength:65536){[weak self] data,_,complete,error in guard let self else{return};self.receiveQueue.async {if let data{let s=self.stream.append(data);if !s.isEmpty{onServices(s)};for ping in self.stream.keepalives{var reply=Data([0,0,0,1]);reply.append(ping.prefix(16));reply.append(self.ourIdentity.prefix(16));reply.append(ping.suffix(8));c.send(content:reply,completion:.contentProcessed{_ in})};self.stream.keepalives.removeAll()};if let error{onState("failed: \(error.localizedDescription)")}else if complete{onState("closed")}else{self.receive(c,onState:onState,onServices:onServices)}}}}
}
private extension Data { func u16(_ i:Int)->UInt16{UInt16(self[index(startIndex,offsetBy:i)])<<8|UInt16(self[index(startIndex,offsetBy:i+1)])};func u32(_ i:Int)->UInt32{UInt32(self[index(startIndex,offsetBy:i)])<<24|UInt32(self[index(startIndex,offsetBy:i+1)])<<16|UInt32(self[index(startIndex,offsetBy:i+2)])<<8|UInt32(self[index(startIndex,offsetBy:i+3)])} }
