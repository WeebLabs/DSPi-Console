/// Loaded once, as with the bar renderer; no offline Metal compiler required.
enum RtaCurveShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct Uniforms {
        float4 viewport; // logical width, height, backing scale, point count
        float4 color;
        float4 style; // line width, opacity, fade start, fade enabled
        float4 gradient; // top opacity, bottom opacity, first fill x, fill sample step
    };
    struct Vertex {
        float4 position [[position]];
        float2 screen;
        float edge;
    };
    float4 position(float2 p, constant Uniforms &u) {
        return float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
    }
    float fade(float x, constant Uniforms &u) {
        return u.style.w > 0 ? saturate((x - u.style.z) / 30.0f) : 1.0f;
    }
    float4 tinted(float alpha, constant Uniforms &u) {
        alpha *= u.color.a;
        return float4(u.color.rgb * alpha, alpha);
    }
    vertex Vertex rtaCurveFill(uint id [[vertex_id]], const device float2 *points [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
        const float2 corners[] = {{0,0}, {1,0}, {0,1}, {1,1}};
        float2 p(mix(points[0].x, points[uint(u.viewport.w) - 1].x, corners[id].x),
                 corners[id].y * u.viewport.y);
        return {position(p, u), p, 0};
    }
    fragment float4 rtaCurveFillColor(Vertex in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                      const device float2 *points [[buffer(0)]]) {
        float index = clamp((in.screen.x - u.gradient.z) / u.gradient.w, 0.0f, u.viewport.w - 1);
        uint i = min(uint(index), uint(u.viewport.w) - 2);
        float height = mix(points[i].y, points[i + 1].y, index - float(i));
        float distance = in.screen.y - height;
        float coverage = saturate(distance / max(fwidth(distance), 0.0001f) + 0.5f);
        float alpha = mix(u.gradient.x, u.gradient.y, saturate(in.screen.y / u.viewport.y));
        return tinted(alpha * coverage * u.style.y * fade(in.screen.x, u), u);
    }
    float2 direction(float2 a, float2 b) {
        float2 d = b - a;
        return d * rsqrt(max(dot(d, d), 1e-12f));
    }
    vertex Vertex rtaCurveStroke(uint id [[vertex_id]], const device float2 *points [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]]) {
        uint i = id / 2, last = uint(u.viewport.w) - 1;
        float2 p = points[i];
        float2 a = direction(points[i > 0 ? i - 1 : i], points[min(i + 1, last)]);
        float2 before = i == 0 ? a : direction(points[i - 1], p);
        float2 after = i == last ? a : direction(p, points[i + 1]);
        float2 n0(-before.y, before.x), n1(-after.y, after.x);
        float2 m = n0 + n1;
        m *= rsqrt(max(dot(m, m), 1e-12f));
        // Limit the join at sharp FFT peaks instead of producing long spikes.
        float join = min(2.0f, 1.0f / max(dot(m, n1), 0.001f));
        float edge = (id % 2 ? 1.0f : -1.0f) * (u.style.x * 0.5f + 1.0f / u.viewport.z);
        float2 screen = p + m * edge * join;
        return {position(screen, u), screen, edge};
    }
    fragment float4 rtaCurveStrokeColor(Vertex in [[stage_in]], constant Uniforms &u [[buffer(1)]]) {
        float aa = 1.0f / u.viewport.z;
        float coverage = saturate((u.style.x * 0.5f - abs(in.edge)) / aa + 0.5f);
        return tinted(coverage * u.style.y * fade(in.screen.x, u), u);
    }
    vertex Vertex rtaCurveQuad(uint id [[vertex_id]], constant Uniforms &u [[buffer(1)]]) {
        const float2 p[] = {{0,0}, {1,0}, {0,1}, {1,1}};
        float2 screen = p[id] * u.viewport.xy;
        return {position(screen, u), screen, 0};
    }
    fragment float4 rtaCurveComposite(Vertex in [[stage_in]], constant Uniforms &u [[buffer(1)]],
                                       texture2d<float> source [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return source.sample(linearSampler, in.screen / u.viewport.xy) * fade(in.screen.x, u);
    }
    """
}
