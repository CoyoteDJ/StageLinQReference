import SwiftUI

struct DiagnosticView: View {
    @ObservedObject var model: ReferenceModel
    var body: some View {
        VStack(alignment: .leading) {
            Text("Diagnostics").font(.title2)
            Text("Raw packet trace").bold()
            List(model.trace.suffix(300)) { r in Text("\(r.timestamp.formatted(date: .omitted, time: .standard)) \(r.direction) \(r.transport) \(r.endpoint) \(r.bytes)B  \(r.hexPreview)").font(.caption) }
            Text("Decoded records").bold()
            List(model.decoded.suffix(100), id: \.self) { Text($0).font(.caption) }
        }.padding()
    }
}
