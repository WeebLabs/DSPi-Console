/// Compiled once per process by Metal, then reused by every bar surface.
/// Keeping the small shader here also supports Xcode installs without the optional
/// offline Metal compiler component. No shader compilation occurs in the draw loop.
enum RtaBarShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    
    // Matches RtaBarInstance. Coordinates and corner radii are in logical points.
    struct BarInstance {
        float4 rect;
        float4 clip;
        float4 color;
        float4 style; // radius, top opacity, bottom opacity, unused
    };
    
    struct BarVertex {
        float4 position [[position]];
        float2 local;
        float2 screen;
        uint instance [[flat]];
    };
    
    vertex BarVertex rtaBarVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                 const device BarInstance *bars [[buffer(0)]],
                                 constant float2 &viewport [[buffer(1)]]) {
        const float2 corners[] = { {0,0}, {1,0}, {0,1}, {0,1}, {1,0}, {1,1} };
        BarInstance bar = bars[instanceID];
        // A one-point fringe leaves room for analytic antialiasing at Retina scales.
        float2 local = corners[vertexID] * (bar.rect.zw + 2.0f) - 1.0f;
        float2 screen = bar.rect.xy + local;
        BarVertex out;
        out.position = float4(screen.x / viewport.x * 2.0f - 1.0f,
                              1.0f - screen.y / viewport.y * 2.0f, 0, 1);
        out.local = local;
        out.screen = screen;
        out.instance = instanceID;
        return out;
    }
    
    fragment float4 rtaBarFragment(BarVertex in [[stage_in]],
                                   const device BarInstance *bars [[buffer(0)]]) {
        BarInstance bar = bars[in.instance];
        if (any(in.screen < bar.clip.xy) || any(in.screen > bar.clip.zw)) discard_fragment();
        float2 halfSize = bar.rect.zw * 0.5f;
        float radius = min(bar.style.x, min(halfSize.x, halfSize.y));
        float2 q = abs(in.local - halfSize) - halfSize + radius;
        float distance = length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - radius;
        float coverage = saturate(0.5f - distance / max(fwidth(distance), 0.0001f));
        float t = saturate(in.local.y / max(bar.rect.w, 0.0001f));
        float alpha = bar.color.a * mix(bar.style.y, bar.style.z, t) * coverage;
        return float4(bar.color.rgb * alpha, alpha); // premultiplied alpha
    }
    """
}
