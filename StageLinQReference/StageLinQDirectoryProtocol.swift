import Foundation
enum DirectoryParser {
    static func parse(_ data: Data) -> [String:Int] {
        guard let text=String(data:data,encoding:.utf8) else { return [:] }
        return Dictionary(uniqueKeysWithValues: text.split(separator:"\n").compactMap { p -> (String,Int)? in let x=p.split(separator:"=",maxSplits:1); return x.count==2 ? (String(x[0]),Int(x[1]) ?? -1) : nil }.filter{$0.1>0})
    }
}
struct TCPFrameAssembler { private(set) var buffer=Data(); mutating func append(_ data:Data,length:Int)->[Data] { buffer.append(data); var out=[Data](); while buffer.count >= length { out.append(buffer.prefix(length)); buffer.removeFirst(length) }; return out } }
