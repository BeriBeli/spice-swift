#include <metal_stdlib>

using namespace metal;

struct SpicePresentationVertex {
    float4 position [[position]];
    float2 textureCoordinate;
};

vertex SpicePresentationVertex spice_present_vertex(
    uint vertexID [[vertex_id]]
) {
    // One oversized triangle covers the drawable without a vertex buffer.
    const float2 textureCoordinates[] = {
        float2(0.0f, 0.0f),
        float2(2.0f, 0.0f),
        float2(0.0f, 2.0f),
    };
    const float2 coordinate = textureCoordinates[vertexID];
    SpicePresentationVertex result;
    result.position = float4(
        coordinate * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f),
        0.0f,
        1.0f
    );
    result.textureCoordinate = coordinate;
    return result;
}

fragment float4 spice_present_fragment(
    SpicePresentationVertex input [[stage_in]],
    texture2d<float, access::sample> source [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]
) {
    return source.sample(sourceSampler, input.textureCoordinate);
}
