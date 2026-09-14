import XCTest

@testable import AdapterMac

final class AdapterMacTests: XCTestCase {
    func testAdapterNameIsSet() {
        XCTAssertEqual(adapterName, "adapter-mac")
    }
}
