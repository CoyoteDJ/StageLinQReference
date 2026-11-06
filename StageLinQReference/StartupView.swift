import SwiftUI

struct StartupView: View {
    @ObservedObject var model: ReferenceModel
    private let directoryServices = ["Directory", "StateMap", "Broadcast", "Syncing", "TimeSynchronization", "BeatInfo", "FileTransfer"]
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading) {
                Text("StageLinQ Reference").font(.title2)
                HStack { Button("Start") { model.start() }; Button("Replay") { model.replay() } }
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                GroupBox("PORT MATRIX — 7 SERVICES") {
                    let players = Array(model.devices.filter({ $0.role == "mixer" || $0.softwareName.uppercased().hasPrefix("JP") }))
                    if players.isEmpty {
                        Text("No players discovered yet.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: true) {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                            GridRow {
                                Text("Service").bold()
                                ForEach(players) { d in
                                    VStack(alignment: .leading) {
                                        Text(d.name).bold()
                                        Text("\(d.role) · \(d.ip)").font(.caption2)
                                    }
                                }
                            }
                            ForEach(directoryServices, id: \.self) { service in
                                GridRow {
                                    Text(service).font(.caption)
                                    ForEach(players) { d in
                                        Text(service == "Directory" ? (d.directoryPort.map(String.init) ?? "not announced") : (d.services[service].map(String.init) ?? (d.directoryState.hasPrefix("failed") || d.directoryState == "closed" ? "failed" : "not announced")))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(d.services[service] == nil ? .secondary : .primary)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 12)
                        }
                    }
                }
                GroupBox("LOGICAL STREAMS") {
                    if model.logicalStreams.isEmpty {
                        ForEach(1...2, id: \.self) { player in
                            ForEach(["Layer A", "Layer B"], id: \.self) { layer in
                                Text("Player \(player) \(layer) · waiting for player discovery · StateMap waiting · BeatInfo waiting").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ForEach(model.logicalStreams) { stream in
                            Text("Player \(stream.playerNumber) \(stream.layer) · StateMap \(stream.stateMapState) · BeatInfo \(stream.beatInfoState)").font(.caption)
                        }
                    }
                }
                GroupBox("MIXER TELEMETRY") {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(1...4, id: \.self) { channel in
                            Text("CH\(channel) fader: \(model.mixerFaders[channel].map { String(format: "%.3f", $0) } ?? "not reported") · assignment: \(model.mixerAssignments[channel].map(String.init) ?? "not reported")").font(.caption.monospacedDigit())
                        }
                        Text("Crossfader: \(model.mixerCrossfader.map { String(format: "%.3f", $0) } ?? "not reported")").font(.caption.monospacedDigit())
                    }
                }
                List(model.devices) { d in
                    VStack(alignment: .leading) {
                        Text("\(d.role): \(d.name)").bold()
                        let port = d.directoryPort.map(String.init) ?? "-"
                        let announcedServices = d.services.keys.filter { $0 != "Directory" }.count
                        Text("\(d.ip)  token: \(d.token)  dir: \(port)")
                        Text("directory \(d.directoryState) · services \(announcedServices)/6 · StateMap \(d.stateMapState) · BeatInfo \(d.beatInfoState)").font(.caption)
                        ForEach(d.services.sorted(by: {$0.key < $1.key}), id: \.key) { Text("\($0.key): \($0.value)").font(.caption2) }
                    }
                }
            }.padding()
        } detail: { HStack(spacing: 0) { DiagnosticView(model: model); Divider(); DeckTelemetryView(model: model).frame(minWidth: 360, idealWidth: 420) } }
    }
}

struct DeckTelemetryView: View {
    @ObservedObject var model: ReferenceModel
    private func number(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.3f", value)
    }
    private func oneDecimal(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f", value)
    }
    var body: some View {
        VStack(alignment: .leading) {
            Text("Live deck telemetry").font(.title2)
            Text("Decoded StateMap and BeatInfo values").font(.caption).foregroundStyle(.secondary)
            ScrollView { LazyVStack(alignment: .leading, spacing: 10) {
                if model.deckTelemetry.isEmpty {
                    ForEach(1...2, id: \.self) { player in
                        ForEach(["Layer A", "Layer B"], id: \.self) { layer in
                            GroupBox("Player \(player) \(layer)") {
                                Text("Waiting for player discovery and service negotiation…")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                ForEach(model.deckTelemetry) { d in
                GroupBox("Player \(d.playerNumber) \(d.layer)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(d.deviceIP) · \(d.playback)").font(.caption)
                        Text("Status: \(d.loaded) · Sync: \(d.syncState) · Master: \(d.master)").font(.caption)
                        Text(d.title).font(.headline).lineLimit(2)
                        Text(d.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        Text("Key \(d.key) · Position \(oneDecimal(d.trackPosition)) · Length \(oneDecimal(d.trackLength))").font(.caption.monospacedDigit())
                        Text("BPM \(number(d.bpm)) · Beat \(number(d.beat)) · Speed \(number(d.speed))").font(.caption.monospacedDigit())
                        Text("Effective volume \(number(d.effectiveVolume)) · Channel \(number(d.channelVolume)) · Crossfader \(number(d.crossfader))").font(.caption.monospacedDigit())
                        if !d.states.isEmpty {
                            Divider()
                            Text("All decoded StateMap values").font(.caption.bold())
                            ForEach(d.states.keys.sorted(), id: \.self) { key in
                                Text("\(key): \(d.states[key] ?? "")").font(.caption2.monospaced())
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } } }.frame(maxHeight: .infinity)
        }.padding()
    }
}
