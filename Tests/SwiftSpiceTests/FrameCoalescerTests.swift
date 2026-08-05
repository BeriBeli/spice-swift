import Foundation
import Testing
@testable import SwiftSpice

@Suite("Input mappings")
struct InputMappingTests {
    @Test func symbolicKeysHaveUniqueXTSetOneCodes() {
        let scanCodes = SpicePhysicalKey.allCases.map(\.scanCode)
        #expect(Set(scanCodes).count == scanCodes.count)
        #expect(SpicePhysicalKey.leftControl.scanCode == 0x1d)
        #expect(SpicePhysicalKey.rightControl.scanCode == 0x11d)
        #expect(SpicePhysicalKey.enter.scanCode == 0x1c)
        #expect(SpicePhysicalKey.keypadEnter.scanCode == 0x11c)
        #expect(SpicePhysicalKey.deleteForward.scanCode == 0x153)
    }

    @Test func mapsMacPhysicalKeysThroughThePublicAuthority() {
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: 0) == .a)
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: 36) == .enter)
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: 76) == .keypadEnter)
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: 62) == .rightControl)
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: 123) == .arrowLeft)
        #expect(SpiceKeyMap.scanCode(forMacVirtualKeyCode: 123) == 0x14b)
        #expect(SpiceKeyMap.physicalKey(forMacVirtualKeyCode: .max) == nil)
        #expect(MacXTScanCode.map[0] == SpicePhysicalKey.a.scanCode)
        #expect(SpicePointerMode(spiceMouseMode: 1) == .relative)
        #expect(SpicePointerMode(spiceMouseMode: 2) == .absolute)
    }

}
