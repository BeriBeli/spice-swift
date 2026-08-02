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

struct SpiceFillUniforms {
    uint4 rectangle;
    float4 colorRGBA;
};

kernel void spice_fill_rect(
    texture2d<float, access::write> destination [[texture(0)]],
    constant SpiceFillUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (any(position >= uniforms.rectangle.zw)) {
        return;
    }
    destination.write(uniforms.colorRGBA, uniforms.rectangle.xy + position);
}

struct SpiceBitmapUniforms {
    // x/y: bitmap dimensions, z: source stride in bytes.
    uint4 sourceGeometry;
    uint4 sourceRectangle;
    uint4 destinationRectangle;
    // x: top-down, y: preserve alpha.
    uint4 flags;
};

kernel void spice_bitmap_copy(
    device const uchar *sourceBytes [[buffer(0)]],
    constant SpiceBitmapUniforms &uniforms [[buffer(1)]],
    texture2d<float, access::write> destination [[texture(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (any(position >= uniforms.destinationRectangle.zw)) {
        return;
    }
    const uint2 sourcePosition = uniforms.sourceRectangle.xy + uint2(
        position.x * uniforms.sourceRectangle.z / uniforms.destinationRectangle.z,
        position.y * uniforms.sourceRectangle.w / uniforms.destinationRectangle.w
    );
    const uint sourceY = uniforms.flags.x != 0
        ? sourcePosition.y
        : uniforms.sourceGeometry.y - 1u - sourcePosition.y;
    const uint offset = sourceY * uniforms.sourceGeometry.z + sourcePosition.x * 4u;
    const float4 rgba = float4(
        float(sourceBytes[offset + 2u]),
        float(sourceBytes[offset + 1u]),
        float(sourceBytes[offset]),
        uniforms.flags.y != 0 ? float(sourceBytes[offset + 3u]) : 255.0f
    ) / 255.0f;
    destination.write(rgba, uniforms.destinationRectangle.xy + position);
}

struct SpiceSurfaceCopyUniforms {
    uint4 sourceRectangle;
    uint4 destinationRectangle;
    // x: preserve alpha.
    uint4 flags;
};

kernel void spice_surface_copy(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant SpiceSurfaceCopyUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (any(position >= uniforms.destinationRectangle.zw)) {
        return;
    }
    float4 rgba = source.read(uniforms.sourceRectangle.xy + position);
    if (uniforms.flags.x == 0) {
        rgba.a = 1.0f;
    }
    destination.write(rgba, uniforms.destinationRectangle.xy + position);
}
