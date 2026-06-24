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

    func test_configure_setsWrapperSynchronously() {
        // configure() assigns SDKIdentity.wrapper before its async work, so the
        // identity is in place before any request is built.
        Galva.configure(
            apiKey: "gv_pub_test",
            wrapper: SDKWrapper(name: "react-native-android", version: "9.9.9")
        )
        XCTAssertEqual(SDKIdentity.header, "react-native-android/9.9.9")
    }
}
