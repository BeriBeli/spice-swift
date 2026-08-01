import Foundation
import Testing
@testable import SwiftSpice

@Suite("Input mappings")
struct InputMappingTests {
    @Test func mapsMacPhysicalKeysToXTSetOne() {
        #expect(MacXTScanCode.map[0] == 0x1e) // A
        #expect(MacXTScanCode.map[36] == 0x1c) // Return
        #expect(MacXTScanCode.map[123] == 0x14b) // E0 Left Arrow
        #expect(SpicePointerMode(spiceMouseMode: 1) == .relative)
        #expect(SpicePointerMode(spiceMouseMode: 2) == .absolute)
    }

}
