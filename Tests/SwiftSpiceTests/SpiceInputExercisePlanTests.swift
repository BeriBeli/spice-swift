import Testing
@testable import SwiftSpice

@Suite("Input exercise plan")
struct SpiceInputExercisePlanTests {
    @Test func absolutePlanUsesChangingDisplayPositionsBeforeClick() throws {
        let inputs = SpiceInputExercisePlan.inputs(for: .absolute)

        let positions = inputs.enumerated().compactMap { index, input in
            if case let .mousePosition(x, y, displayID) = input {
                return (index: index, x: x, y: y, displayID: displayID)
            }
            return nil
        }
        let motions = inputs.filter {
            if case .mouseMotion = $0 { return true }
            return false
        }

        #expect(positions.count >= 2)
        #expect(positions.allSatisfy { $0.displayID == 0 })
        let firstPosition = try #require(positions.first)
        #expect(positions.dropFirst().contains {
            $0.x != firstPosition.x || $0.y != firstPosition.y
        })
        #expect(motions.isEmpty)
        try expectKeyboardThenPointerThenClick(inputs)
    }

    @Test func relativePlanUsesMotionInsteadOfAbsolutePositionsBeforeClick() throws {
        let inputs = SpiceInputExercisePlan.inputs(for: .relative)

        let motions = inputs.enumerated().compactMap { index, input in
            if case let .mouseMotion(dx, dy) = input {
                return (index: index, dx: dx, dy: dy)
            }
            return nil
        }
        let positions = inputs.filter {
            if case .mousePosition = $0 { return true }
            return false
        }

        #expect(!motions.isEmpty)
        #expect(motions.contains { $0.dx != 0 || $0.dy != 0 })
        #expect(positions.isEmpty)
        try expectKeyboardThenPointerThenClick(inputs)
    }

    private func expectKeyboardThenPointerThenClick(_ inputs: [SpiceClientInput]) throws {
        let keyDowns = inputs.enumerated().compactMap { index, input in
            if case let .keyDown(scanCode) = input {
                return (index: index, scanCode: scanCode)
            }
            return nil
        }
        let keyUps = inputs.enumerated().compactMap { index, input in
            if case let .keyUp(scanCode) = input {
                return (index: index, scanCode: scanCode)
            }
            return nil
        }
        let keyDown = try #require(keyDowns.first)
        let keyUp = try #require(keyUps.first)
        let keyboardIndices = inputs.indices.filter { index in
            switch inputs[index] {
            case .keyDown, .keyUp, .lockModifiers:
                true
            case .mouseMotion, .mousePosition, .mousePress, .mouseRelease:
                false
            }
        }
        let lastKeyboard = try #require(keyboardIndices.last)
        let firstPointer = try #require(inputs.firstIndex {
            switch $0 {
            case .mouseMotion, .mousePosition, .mousePress, .mouseRelease:
                true
            case .keyDown, .keyUp, .lockModifiers:
                false
            }
        })
        let movementIndices = inputs.indices.filter { index in
            switch inputs[index] {
            case .mouseMotion, .mousePosition:
                true
            default:
                false
            }
        }
        let lastMovement = try #require(movementIndices.last)
        let leftPress = try #require(inputs.firstIndex {
            if case .mousePress(.left) = $0 { return true }
            return false
        })
        let leftRelease = try #require(inputs.firstIndex {
            if case .mouseRelease(.left) = $0 { return true }
            return false
        })

        #expect(keyDowns.count == 1)
        #expect(keyUps.count == 1)
        #expect(keyDown.scanCode == keyUp.scanCode)
        #expect(keyDown.index < keyUp.index)
        #expect(lastKeyboard < firstPointer)
        #expect(lastMovement < leftPress)
        #expect(leftPress < leftRelease)
    }
}
