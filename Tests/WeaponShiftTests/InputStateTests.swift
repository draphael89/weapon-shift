import XCTest
@testable import WeaponShift

final class InputStateTests: XCTestCase {
    func testKeyboardSourcesKeepSharedActionsHeldUntilEverySourceReleases() {
        var input = InputState()

        input.setKeyboard(.dash, source: "key-k", isDown: true)
        XCTAssertTrue(input.wasPressed(.dash))
        input.endFrame()

        input.setKeyboard(.dash, source: "modifier-shift", isDown: true)
        input.endFrame()

        input.setKeyboard(.dash, source: "modifier-shift", isDown: false)
        XCTAssertTrue(input.held(.dash))

        input.setKeyboard(.dash, source: "key-k", isDown: false)
        XCTAssertFalse(input.held(.dash))
    }

    func testGamepadClearReleasesHeldActionsWithoutAddingPresses() {
        var input = InputState()

        input.setGamepad(.attack, isDown: true)
        input.setGamepad(.dash, isDown: true)
        XCTAssertTrue(input.wasPressed(.attack))
        input.endFrame()

        input.clearGamepad()

        XCTAssertFalse(input.held(.attack))
        XCTAssertFalse(input.held(.dash))
        XCTAssertFalse(input.wasPressed(.attack))
    }

    func testKeyboardAndGamepadPressesAreTrackedIndependently() {
        var input = InputState()

        input.setKeyboard(.restart, source: "key-r", isDown: true)
        input.endFrame()
        input.setGamepad(.restart, isDown: true)

        XCTAssertTrue(input.held(.restart))
        XCTAssertTrue(input.wasPressed(.restart))
    }

    func testAnyPressMatchesTitleScreenAnyButtonContract() {
        for action in InputAction.allCases {
            var input = InputState()

            input.setKeyboard(action, source: "key-\(action)", isDown: true)

            XCTAssertTrue(input.hasAnyPress)
        }
    }
}
