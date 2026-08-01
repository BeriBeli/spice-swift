#include <metal_stdlib>

using namespace metal;

struct SpiceVideoCompositorUniforms {
    // x/y: source size, z: flip source vertically, w: reserved.
    uint4 sourceAndFlags;
    // x/y: logical source origin, z/w: logical source size.
    uint4 sourceRect;
    // x/y: destination origin, z/w: destination size.
    uint4 destinationRect;
    // x/y: clip origin, z/w: clip size.
    uint4 clipRect;
    // x: luma offset, y: luma scale, z: chroma offset, w: chroma scale.
    float4 rangeParameters;
    float4 redCoefficients;
    float4 greenCoefficients;
    float4 blueCoefficients;
};

kernel void spice_nv12_to_bgra(
    texture2d<float, access::read> luma [[texture(0)]],
    texture2d<float, access::read> chroma [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant SpiceVideoCompositorUniforms &uniforms [[buffer(0)]],
    uint2 positionInClip [[thread_position_in_grid]]
) {
    const uint2 clipSize = uniforms.clipRect.zw;
    if (any(positionInClip >= clipSize)) {
        return;
    }

    const uint2 destinationPosition = uniforms.clipRect.xy + positionInClip;
    const uint2 destinationOrigin = uniforms.destinationRect.xy;
    const uint2 destinationSize = uniforms.destinationRect.zw;
    if (any(destinationPosition < destinationOrigin)
        || any(destinationPosition >= destinationOrigin + destinationSize)) {
        return;
    }

    const uint2 relativePosition = destinationPosition - destinationOrigin;
    const uint2 sourceSize = uniforms.sourceAndFlags.xy;

    // Match SurfaceStore's integer nearest-neighbor reference path exactly.
    uint2 sourcePosition = uniforms.sourceRect.xy + uint2(
        relativePosition.x * uniforms.sourceRect.z / destinationSize.x,
        relativePosition.y * uniforms.sourceRect.w / destinationSize.y
    );
    sourcePosition = min(sourcePosition, sourceSize - 1u);
    if (uniforms.sourceAndFlags.z != 0u) {
        sourcePosition.y = sourceSize.y - 1u - sourcePosition.y;
    }

    const float rawLuma = luma.read(sourcePosition).r;
    const float2 rawChroma = chroma.read(sourcePosition / 2u).rg;
    const float3 yCbCr = float3(
        (rawLuma - uniforms.rangeParameters.x) * uniforms.rangeParameters.y,
        (rawChroma.x - uniforms.rangeParameters.z) * uniforms.rangeParameters.w,
        (rawChroma.y - uniforms.rangeParameters.z) * uniforms.rangeParameters.w
    );

    const float3 rgb = clamp(float3(
        dot(uniforms.redCoefficients.xyz, yCbCr) + uniforms.redCoefficients.w,
        dot(uniforms.greenCoefficients.xyz, yCbCr) + uniforms.greenCoefficients.w,
        dot(uniforms.blueCoefficients.xyz, yCbCr) + uniforms.blueCoefficients.w
    ), 0.0f, 1.0f);

    destination.write(float4(rgb, 1.0f), destinationPosition);
}
