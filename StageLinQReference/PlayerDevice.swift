import Foundation
struct PlayerDevice: Identifiable {
    let id: String; var token: String; var role: String; var ip: String; var name: String; var softwareName: String = ""
    var directoryPort: Int?; var sessionGeneration = 0; var directoryState = "not connected"; var stateMapState = "not connected"; var beatInfoState = "not connected"; var services: [String:Int] = [:]
    var tableLocked: Bool {
        // Directory itself is learned from Discovery; the remaining six
        // services must arrive through the Directory stream.
        services.keys.filter { $0 != "Directory" }.count >= 6 && directoryState == "locked"
    }
}
struct LogicalStream: Identifiable {
    let id: String
    let playerIdentity: String
    let playerNumber: Int
    let layer: String
    var stateMapState: String
    var beatInfoState: String
}
struct DeckTelemetry: Identifiable {
    let id: String
    var playerNumber: Int
    var layer: String
    var deviceIP: String
    var title = "Unavailable"
    var artist = "Unavailable"
    var playback = "Unavailable"
    var loaded = "Unknown"
    var trackLength: Double?
    var trackPosition: Double?
    var key = "Unavailable"
    var loopState = "Unavailable"
    var syncState = "Unavailable"
    var master = "Unavailable"
    var channelVolume: Double?
    var crossfader: Double?
    var bpm: Double?
    var beat: Double?
    var speed: Double?
    var effectiveVolume: Double?
    var lastRaw = ""
    var states: [String:String] = [:]
}
struct ServiceTable { let identity: String; let generation: Int; let ports: [String:Int] }
final class ServiceTableLock {
    private var tables: [String:ServiceTable] = [:]
    func lock(_ table: ServiceTable) { tables[table.identity] = table }
    func table(for identity: String, generation: Int) -> ServiceTable? { guard let t = tables[identity], t.generation == generation else { return nil }; return t }
}
