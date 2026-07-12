import XCTest
@testable import AudioEngine

final class AirPodsIdentifierTests: XCTestCase {

    func testKnownH2ModelsClassifyAsStudioCapable() {
        for pid in [0x2014, 0x2024, 0x2019, 0x201B, 0x2027] {
            let info = AirPodsIdentifier.classify(vendorID: 0x004C, productID: pid)
            XCTAssertNotNil(info, "PID 0x\(String(pid, radix: 16)) must be known")
            XCTAssertEqual(info?.chip, .h2OrNewer)
        }
    }

    func testKnownH1ModelsClassifyAsLegacy() {
        for pid in [0x2002, 0x200F, 0x2013, 0x200E, 0x200A] {
            let info = AirPodsIdentifier.classify(vendorID: 0x004C, productID: pid)
            XCTAssertNotNil(info, "PID 0x\(String(pid, radix: 16)) must be known")
            XCTAssertEqual(info?.chip, .h1Family)
        }
    }

    func testNonAppleVendorRejected() {
        XCTAssertNil(AirPodsIdentifier.classify(vendorID: 0x1234, productID: 0x2014))
    }

    func testUnknownProductDegradesToNil() {
        // Unknown Apple audio PID → nil → caller uses the name heuristic.
        XCTAssertNil(AirPodsIdentifier.classify(vendorID: 0x004C, productID: 0x7FFF))
    }

    func testModelNamesAreHumanReadable() {
        let pro2 = AirPodsIdentifier.classify(vendorID: 0x004C, productID: 0x2014)
        XCTAssertEqual(pro2?.modelName, "AirPods Pro 2")
        let pro2c = AirPodsIdentifier.classify(vendorID: 0x004C, productID: 0x2024)
        XCTAssertEqual(pro2c?.modelName, "AirPods Pro 2 (USB-C)")
    }
}
