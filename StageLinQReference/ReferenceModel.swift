import Foundation
import Combine

@MainActor final class ReferenceModel: ObservableObject {
    @Published var status="Ready for broadcast player discovery."; @Published var devices=[PlayerDevice](); @Published var logicalStreams=[LogicalStream](); @Published var deckTelemetry=[DeckTelemetry](); @Published var mixerFaders=[Int:Double](); @Published var mixerAssignments=[Int:Int](); @Published var mixerCrossfader: Double?; @Published var trace=[PacketTraceRecord](); @Published var decoded=[String]()
    private let discovery=StageLinQDiscovery(); private var directories=[String:DirectoryConnection](); private var stateMaps=[String:StateMapConnection](); private var beatInfos=[String:BeatInfoConnection](); private var winningIdentityByIP=[String:String]()
    func addTrace(_ record: PacketTraceRecord) { trace.append(record); if trace.count > 300 { trace.removeFirst(trace.count - 300) } }
    func addDecoded(_ record: String) { decoded.append(record); if decoded.count > 300 { decoded.removeFirst(decoded.count - 300) } }
    func stop() { discovery.stop(); status="Stopped." }
    func start() { status="Starting broadcast player discovery on UDP 51337 and TCP directory listener…"; discovery.start(listenPort: 51337,onFrame:{ [weak self] data, ip in Task { @MainActor in self?.addTrace(PacketTraceRecord(direction:"in",endpoint:"\(ip):51337",transport:"UDP",bytes:data.count,hexPreview:data.prefix(24).map{String(format:"%02X",$0)}.joined(separator:" "))); self?.ingest(data,ip:ip) } },onTrace:{ _,_,_,_ in },onStatus:{ [weak self] message in Task { @MainActor in self?.status=message } }); DispatchQueue.main.asyncAfter(deadline:.now()+0.25) { self.discovery.announce(onTrace:{ [weak self] bytes, hex, host in Task { @MainActor in self?.addTrace(PacketTraceRecord(direction:"out",endpoint:"\(host):51337",transport:"UDP",bytes:bytes,hexPreview:hex)) } },onResult:{ [weak self] result in Task { @MainActor in self?.addDecoded(result) } }) } }
    func replay() { status="Replay mode: decoder-only; no live hardware claims."; for (i,s) in ["identity=mixer-1\ntoken=mix\nrole=mixer\nname=Denon\ndirectoryPort=50000","identity=player-1\ntoken=p1\nrole=player\nname=SC6000\ndirectoryPort=50001","identity=player-2\ntoken=p2\nrole=player\nname=SC6000M\ndirectoryPort=50002"].enumerated() { ingest(Data(s.utf8),ip:"192.0.2.\(i+1)") } }
    func ingest(_ data:Data,ip:String) { if let f=DiscoveryCodec.decode(data,from:ip) { let local=f.identity == discovery.identity.map({String(format:"%02X",$0)}).joined(); let mixer=f.deviceName.lowercased().contains("mixer") || f.deviceName.lowercased().contains("dn-") || f.softwareName.uppercased().hasPrefix("JM"); let role=local ? "local" : (mixer ? "mixer" : "peer"); upsert(identity:f.identity,token:f.identity,role:role,ip:ip,name:f.deviceName,software:f.softwareName,port:f.servicePort); decoded.append("Binary discovery: \(f.identity) / \(f.connectionType) / \(f.softwareName) \(f.softwareVersion) / \(ip):\(f.servicePort)"); if role == "peer", f.servicePort > 0 { connectDirectory(identity:f.identity,ip:ip,port:f.servicePort) }; return }; guard let a=DiscoveryParser.parse(data,from:ip) else { decoded.append("Rejected malformed announcement from \(ip)"); return }; upsert(identity:a.identity,token:a.token,role:a.role,ip:a.ip,name:a.name,software:a.name,port:a.directoryPort); decoded.append("Text replay announcement: \(a.identity) / \(a.role) / \(a.ip):\(a.directoryPort)") }
    private func connectDirectory(identity:String,ip:String,port:Int){
        // Each discovered device identity is negotiated independently. Do not
        // gate this on identity ordering: a random local token may sort above
        // a player token, and the player would then never receive a directory
        // request at all.
        guard directories[identity] == nil else { return }
        let c=DirectoryConnection()
        directories[identity]=c
        c.connect(ip:ip,port:port,identity:discovery.identity,onState:{[weak self] s in Task{@MainActor in
            guard let self else { return }
            if let i=self.devices.firstIndex(where:{$0.id==identity}) { self.devices[i].directoryState=s }
            self.decoded.append("Directory \(identity): \(s)")
            if s == "connected" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, let device=self.devices.first(where:{$0.id==identity}), device.services.isEmpty, device.directoryState == "connected" else { return }
                    self.decoded.append("Directory \(identity): connected but no service announcements received; services are hidden or this relationship is not authorized.")
                }
            }
            if s.hasPrefix("failed") || s == "closed" {
                if let i=self.devices.firstIndex(where:{$0.id==identity}) {
                    self.devices[i].services.removeAll()
                    self.devices[i].directoryState=s
                }
                self.directories.removeValue(forKey: identity)
            }
        }},onServices:{[weak self] services in Task{@MainActor in
            guard let self, let i=self.devices.firstIndex(where:{$0.id==identity}) else { return }
            for service in services where service.port>0 { self.devices[i].services[service.name]=service.port }
            // Discovery is the authoritative source for the Directory port.
            // Keep it in the same per-player table as the six Directory
            // announcements so the UI can distinguish 7/7 from partial data.
            if let port = self.devices[i].directoryPort, port > 0 { self.devices[i].services["Directory"] = port }
            let announced = self.devices[i].services.keys.filter { $0 != "Directory" }.count
            if announced >= 6 {
                self.devices[i].directoryState="locked"
                if self.winningIdentityByIP[self.devices[i].ip] == nil {
                    self.winningIdentityByIP[self.devices[i].ip] = identity
                    self.decoded.append("Selected (identity) as winning player identity for (self.devices[i].ip)")
                    self.connectTelemetry(for: self.devices[i])
                }
            }
            self.rebuildLogicalStreamsIfReady()
            self.decoded.append("Directory services \(identity): \(services.map{$0.name+":"+String($0.port)}.joined(separator:", "))")
        }})
    }
    private func initiatesDirectoryConnection(to hexIdentity:String) -> Bool {
        let values = stride(from: 0, to: hexIdentity.count, by: 2).compactMap { offset -> UInt8? in
            let start = hexIdentity.index(hexIdentity.startIndex, offsetBy: offset)
            let end = hexIdentity.index(start, offsetBy: 2)
            return UInt8(hexIdentity[start..<end], radix: 16)
        }
        guard values.count == 16 else { return false }
        return lexicographicallyPrecedes(discovery.identity, identity: Data(values))
    }
    private func lexicographicallyPrecedes(_ lhs:Data, identity rhs:Data) -> Bool {
        for (a,b) in zip(lhs,rhs) { if a != b { return a < b } }
        return false
    }
    private func rebuildLogicalStreamsIfReady() {
        let decks = devices.filter { $0.softwareName.uppercased().hasPrefix("JP") && $0.tableLocked && winningIdentityByIP[$0.ip] == $0.id }.sorted { $0.ip < $1.ip }
        guard decks.count >= 2 else { logicalStreams.removeAll(); return }
        let selected = Array(decks.prefix(2))
        logicalStreams = selected.enumerated().flatMap { index, device in
            [LogicalStream(id: "\(device.id)-A", playerIdentity: device.id, playerNumber: index + 1, layer: "Layer A", stateMapState: device.stateMapState, beatInfoState: device.beatInfoState), LogicalStream(id: "\(device.id)-B", playerIdentity: device.id, playerNumber: index + 1, layer: "Layer B", stateMapState: device.stateMapState, beatInfoState: device.beatInfoState)]
        }
        status = "Two player service tables locked; four logical streams created."
        for (index, device) in selected.enumerated() {
            for layer in ["Layer A", "Layer B"] {
                let id = "\(device.id)-\(layer)"
                if !deckTelemetry.contains(where: { $0.id == id }) { deckTelemetry.append(DeckTelemetry(id: id, playerNumber: index + 1, layer: layer, deviceIP: device.ip)) }
            }
        }
    }
    private func connectTelemetry(for device: PlayerDevice) {
        guard device.tableLocked else { return }
        let localIdentity = discovery.identity
        if stateMaps[device.id] == nil { let c=StateMapConnection(); stateMaps[device.id]=c; c.onState={ [weak self] s in Task{@MainActor in guard let self else{return}; if let i=self.devices.firstIndex(where:{$0.id==device.id}){self.devices[i].stateMapState=s}; self.syncLogicalStreamStates(); self.decoded.append("StateMap \(device.id): \(s)"); if s.hasPrefix("failed") || s == "closed" { self.stateMaps.removeValue(forKey: device.id); if let current=self.devices.first(where:{$0.id==device.id}), current.tableLocked { DispatchQueue.main.asyncAfter(deadline:.now()+1.0) { [weak self] in guard let self, let latest=self.devices.first(where:{$0.id==device.id}), latest.tableLocked else{return}; self.connectTelemetry(for: latest) } } } }}; c.onOutbound={ [weak self] packet in Task{@MainActor in self?.decoded.append(packet.prefix(180).description) }}; c.onRaw={ [weak self] raw in Task{@MainActor in self?.decoded.append("StateMap raw inbound \(device.id): \(raw.prefix(96))") }}; c.onRecord={ [weak self] name,value,raw in Task{@MainActor in self?.updateTelemetry(deviceID: device.id, name: name, value: value, raw: raw); self?.decoded.append("StateMap record \(device.id): \(name)=\(value) raw=\(raw.prefix(48))") }}; c.connect(device, localIdentity: localIdentity) }
        if beatInfos[device.id] == nil { let c=BeatInfoConnection(); beatInfos[device.id]=c; c.onState={ [weak self] s in Task{@MainActor in guard let self else{return}; if let i=self.devices.firstIndex(where:{$0.id==device.id}){self.devices[i].beatInfoState=s}; self.syncLogicalStreamStates(); self.decoded.append("BeatInfo \(device.id): \(s)") }}; c.onBeat={ [weak self] deck,beat,total,bpm,raw in Task{@MainActor in self?.updateBeat(deviceID: device.id, deck: deck, beat: beat, total: total, bpm: bpm, raw: raw); self?.decoded.append(String(format:"BeatInfo %@ deck %d: bpm %.3f beat %.3f total %.3f raw=%@",device.id,deck+1,bpm,beat,total,String(raw.prefix(48)))) }}; c.connect(device, localIdentity: localIdentity) }
    }
    private func syncLogicalStreamStates() {
        for i in logicalStreams.indices {
            if let device = devices.first(where: {$0.id == logicalStreams[i].playerIdentity}) {
                logicalStreams[i].stateMapState = device.stateMapState
                logicalStreams[i].beatInfoState = device.beatInfoState
            }
        }
    }
    private func updateTelemetry(deviceID: String, name: String, value: String, raw: String) {
        let cleanValue = stateMapScalar(value)
        if name.hasPrefix("/Mixer/CH"), name.hasSuffix("faderPosition"), let number = Int(String(name.dropFirst(9).prefix(1))), let level = Double(cleanValue) { mixerFaders[number] = level; addDecoded("Mixer channel \(number) fader = \(cleanValue)") }
        if name.contains("/Mixer/CrossfaderPosition"), let level = Double(cleanValue) { mixerCrossfader = level }
        if name.contains("/Mixer/ChannelAssignment"), let channel = Int(name.last.map(String.init) ?? ""), let deck = Int(cleanValue) { mixerAssignments[channel] = deck }
        let layer = (name.contains("/Deck2/") || name.contains("CH2faderPosition") || name.contains("Deck2/ExternalMixerVolume")) ? "Layer B" : "Layer A"
        for i in deckTelemetry.indices where deckTelemetry[i].id == "\(deviceID)-\(layer)" {
            deckTelemetry[i].lastRaw = raw
            deckTelemetry[i].states[name] = cleanValue
            if name.contains("SongName") || name.contains("TrackName") { deckTelemetry[i].title = cleanValue }
            else if name.contains("ArtistName") { deckTelemetry[i].artist = cleanValue }
            else if name.contains("SongLoaded") { deckTelemetry[i].loaded = cleanValue == "true" ? "Loaded" : "Not loaded" }
            else if name.contains("TrackNetworkPath") { deckTelemetry[i].loaded = cleanValue.isEmpty || cleanValue == "null" ? "Not loaded" : "Loaded" }
            else if name.contains("TrackLength") { deckTelemetry[i].trackLength = Double(cleanValue) }
            else if name.contains("TrackPosition") { deckTelemetry[i].trackPosition = Double(cleanValue) }
            else if name.contains("KeyString") { deckTelemetry[i].key = cleanValue }
            else if name.contains("PlayState") || name.hasSuffix("/Play") { deckTelemetry[i].playback = cleanValue }
            else if name.contains("CurrentBPM") { deckTelemetry[i].bpm = Double(cleanValue) }
            else if name.contains("Speed") { deckTelemetry[i].speed = Double(cleanValue) }
            else if name.contains("LoopEnableState") || name.contains("CurrentLoopSizeInBeats") { deckTelemetry[i].loopState = cleanValue }
            else if name.contains("SyncMode") { deckTelemetry[i].syncState = cleanValue }
            else if name.contains("DeckIsMaster") || name.contains("MasterTempo") { deckTelemetry[i].master = cleanValue }
            else if name.contains("Channel") && name.contains("Volume") || name.contains("faderPosition") || name.contains("ExternalMixerVolume") { deckTelemetry[i].channelVolume = Double(cleanValue); deckTelemetry[i].effectiveVolume = Double(cleanValue) }
            else if name.contains("CrossfaderPosition") { deckTelemetry[i].crossfader = Double(cleanValue) }
        }
    }
    private func stateMapScalar(_ value: String) -> String {
        guard let data = value.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) else {
            return value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if let dict = object as? [String: Any] {
            if let s = dict["string"] as? String { return s }
            if let b = dict["state"] as? Bool { return b ? "true" : "false" }
            if let n = dict["value"] as? NSNumber { return n.stringValue }
        }
        return String(describing: object)
    }
    private func updateBeat(deviceID: String, deck: Int, beat: Double, total: Double, bpm: Double, raw: String) {
        let layer = deck == 0 ? "Layer A" : "Layer B"
        for i in deckTelemetry.indices where deckTelemetry[i].id == "\(deviceID)-\(layer)" { deckTelemetry[i].beat = beat; if bpm > 0 { deckTelemetry[i].bpm = bpm }; deckTelemetry[i].states["BeatInfo/TotalBeats"] = String(format:"%.3f",total); deckTelemetry[i].lastRaw = raw }
    }
    private func upsert(identity:String,token:String,role:String,ip:String,name:String,software:String,port:Int) {
        if let i=devices.firstIndex(where:{$0.id==identity}) {
            let endpointChanged = devices[i].ip != ip || devices[i].directoryPort != port
            devices[i].ip=ip; devices[i].directoryPort=port; devices[i].name=name; devices[i].softwareName=software; devices[i].token=token
            if endpointChanged {
                devices[i].sessionGeneration += 1
                devices[i].services.removeAll()
                devices[i].directoryState="not connected"
                directories.removeValue(forKey: identity)
            }
        } else {
            devices.append(PlayerDevice(id:identity,token:token,role:role,ip:ip,name:name,softwareName:software,directoryPort:port,sessionGeneration:1))
        }
    }
}
