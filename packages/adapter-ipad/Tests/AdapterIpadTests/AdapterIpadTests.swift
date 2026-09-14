import XCTest

@testable import AdapterIpad

final class AdapterIpadTests: XCTestCase {
    func testAdapterNameIsSet() {
        XCTAssertEqual(adapterName, "adapter-ipad")
    }
}
