package enum SpiceInputExercisePlan {
    /// A deterministic live-probe sequence that exercises keyboard, pointer,
    /// and primary-button delivery without mixing SPICE pointer modes.
    package static func inputs(for pointerMode: SpicePointerMode) -> [SpiceClientInput] {
        var inputs: [SpiceClientInput] = [
            .keyDown(scanCode: 0x1e),
            .keyUp(scanCode: 0x1e),
        ]

        switch pointerMode {
        case .absolute:
            for step in UInt32(0)..<8 {
                inputs.append(
                    .mousePosition(
                        x: 160 + step * 8,
                        y: 120 + step * 6,
                        displayID: 0
                    )
                )
            }
        case .relative:
            for _ in 0..<8 {
                inputs.append(.mouseMotion(dx: 1, dy: 1))
            }
        }

        inputs.append(.mousePress(.left))
        inputs.append(.mouseRelease(.left))
        return inputs
    }
}
