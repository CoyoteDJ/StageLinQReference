import Foundation
struct PacketTraceRecord: Identifiable { let id = UUID(); let timestamp = Date(); let direction: String; let endpoint: String; let transport: String; let bytes: Int; let hexPreview: String }
