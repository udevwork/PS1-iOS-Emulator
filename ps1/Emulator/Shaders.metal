#include <metal_stdlib>
using namespace metal;

struct QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Полноэкранный квад; масштаб (аспект) передаётся через uniforms
// texScale обрезает текстурные координаты до фактического размера кадра
// внутри текстуры максимального размера
vertex QuadVertexOut screenQuadVertex(uint vid [[vertex_id]],
                                      constant float2 &scale [[buffer(0)]],
                                      constant float2 &texScale [[buffer(1)]]) {
    // Треугольная полоса: (-1,-1) (1,-1) (-1,1) (1,1)
    float2 pos = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    QuadVertexOut out;
    out.position = float4(pos * scale, 0.0, 1.0);
    out.texCoord = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 0.0 : 1.0) * texScale;
    return out;
}

fragment float4 screenQuadFragment(QuadVertexOut in [[stage_in]],
                                   texture2d<float> frame [[texture(0)]],
                                   sampler frameSampler [[sampler(0)]]) {
    return float4(frame.sample(frameSampler, in.texCoord).rgb, 1.0);
}
