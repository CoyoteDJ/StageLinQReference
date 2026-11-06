import XCTest
@testable import StageLinQReference
final class ProtocolTests: XCTestCase {
    func testDiscoveryParsing(){let a=DiscoveryParser.parse(Data("identity=p1\ntoken=t\nrole=player\nname=X\ndirectoryPort=123\n".utf8),from:"1.2.3.4");XCTAssertEqual(a?.identity,"p1");XCTAssertEqual(a?.directoryPort,123)}
    func testDirectoryParsing(){XCTAssertEqual(DirectoryParser.parse(Data("StateMap=10\nBeatInfo=11\n".utf8))["BeatInfo"],11)}
    func testIncompleteFramesReassemble(){var f=TCPFrameAssembler();XCTAssertTrue(f.append(Data([1,2]),length:4).isEmpty);XCTAssertEqual(f.append(Data([3,4,5,6]),length:4),[Data([1,2,3,4])]);XCTAssertEqual(f.buffer,Data([5,6]))}
    func testServiceTableLocksByIdentityAndGeneration(){let l=ServiceTableLock();l.lock(ServiceTable(identity:"p",generation:2,ports:["StateMap":1]));XCTAssertNotNil(l.table(for:"p",generation:2));XCTAssertNil(l.table(for:"p",generation:1))}
    func testStaleGenerationRejected(){let l=ServiceTableLock();l.lock(ServiceTable(identity:"p",generation:3,ports:["BeatInfo":2]));XCTAssertNil(l.table(for:"p",generation:2))}
}
