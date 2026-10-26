import XCTest
@testable import Galva

final class SDKIdentityTests: XCTestCase {
    override func tearDown() {
        SDKIdentity.wrapper = nil // restore the native-core default for other tests
        super.tearDown()
    }

    func test_default_isNativeCore() {
        SDKIdentity.wrapper = nil
        XCTAssertEqual(SDKIdentity.libraryName, "ios")
        XCTAssertEqual(SDKIdentity.version, SDKConstants.version)
        XCTAssertEqual(SDKIdentity.header, "ios/\(SDKConstants.version)")
    }

    func test_wrapperOverride_rebrandsNameAndVersion() {
        SDKIdentity.wrapper = SDKWrapper(name: "react-native-ios", version: "2.3.4")
        XCTAssertEqual(SDKIdentity.libraryName, "react-native-ios")
        XCTAssertEqual(SDKIdentity.version, "2.3.4")
        XCTAssertEqual(SDKIdentity.header, "react-native-ios/2.3.4")
    }

    // `Galva.configure(…, wrapper:)` claims and sets the identity through
    // `claimConfiguration(of:reportingAs:)`, then starts its async work. A
    // fresh core each time, so these run repeatedly in one process and
    // never start a real configure.

    func test_configure_setsWrapperSynchronously() {
        // Assigned before configure's async work, so the identity is in place
        // before any request is built.
        let claimed = Galva.claimConfiguration(
            of: SDKCore(),
            reportingAs: SDKWrapper(name: "react-native-android", version: "9.9.9")
        )
        XCTAssertTrue(claimed)
        XCTAssertEqual(SDKIdentity.header, "react-native-android/9.9.9")
    }

    func test_repeatConfigure_keepsTheFirstWrapper() {
        let core = SDKCore()
        XCTAssertTrue(Galva.claimConfiguration(
            of: core, reportingAs: SDKWrapper(name: "react-native-ios", version: "2.3.4")
        ))
        XCTAssertFalse(Galva.claimConfiguration(
            of: core, reportingAs: SDKWrapper(name: "flutter-ios", version: "1.0.0")
        ))
        XCTAssertEqual(SDKIdentity.header, "react-native-ios/2.3.4")
    }
}
