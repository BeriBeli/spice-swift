import Testing
@testable import SwiftSpice

@Suite("Spice rendering backend policy")
struct SpiceRenderingBackendTests {
    @Test func keepsMetal2DExplicitAndSeparatesBenchmarkBackingModes() {
        #expect(SpiceRenderingBackend.automatic.usesRevisionedIOSurfaceBacking)
        #expect(!SpiceRenderingBackend.automatic.enablesMetal2DRenderer)
        #expect(!SpiceRenderingBackend.automatic.requiresRevisionedBacking)

        #expect(SpiceRenderingBackend.cpu.rawValue == "cpu")
        #expect(!SpiceRenderingBackend.cpu.usesRevisionedIOSurfaceBacking)
        #expect(!SpiceRenderingBackend.cpu.enablesMetal2DRenderer)
        #expect(!SpiceRenderingBackend.cpu.requiresRevisionedBacking)

        #expect(SpiceRenderingBackend.cpuIOSurface.rawValue == "cpu-iosurface")
        #expect(SpiceRenderingBackend.cpuIOSurface.usesRevisionedIOSurfaceBacking)
        #expect(!SpiceRenderingBackend.cpuIOSurface.enablesMetal2DRenderer)
        #expect(SpiceRenderingBackend.cpuIOSurface.requiresRevisionedBacking)

        #expect(SpiceRenderingBackend.metal.usesRevisionedIOSurfaceBacking)
        #expect(SpiceRenderingBackend.metal.enablesMetal2DRenderer)
        #expect(SpiceRenderingBackend.metal.requiresRevisionedBacking)
    }
}
