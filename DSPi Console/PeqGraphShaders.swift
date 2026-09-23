/// Shaders for the on-graph PEQ editor.  Compiled at runtime like the
/// spectrum shaders, so no offline Metal compiler is needed.
///
/// The CPU never evaluates a curve for drawing: it hands over each band's
/// biquad sections in phi form (see `PeqPhiSection`), `peqResponse` evaluates
/// every band, the fixed crossover row and the combined curve at every pixel
/// column in one pass, and the other stages read that table.  Transcendentals
/// use `precise::` because fast-math `sin` loses the tiny phi values that
/// low-frequency, high-Q sections depend on.
enum PeqGraphShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ResponseParams {
        uint columns; uint curves; uint combinedRow; uint pad;
        float logMin; float logSpan; float piOverFs; float pad2;
    };
    struct Section { float4 n; float4 d; };
    struct CurveRange { uint start; uint count; float offsetDB; uint combined; };

    kernel void peqResponse(uint col [[thread_position_in_grid]],
                            constant ResponseParams &p [[buffer(0)]],
                            constant Section *sections [[buffer(1)]],
                            constant CurveRange *curves [[buffer(2)]],
                            device float *table [[buffer(3)]]) {
        if (col >= p.columns) return;
        float t = p.columns > 1 ? float(col) / float(p.columns - 1) : 0.0f;
        float freq = precise::exp10(p.logMin + t * p.logSpan);
        float s = precise::sin(p.piOverFs * freq);
        float phi = s * s;
        float combined = 0.0f;
        for (uint c = 0; c < p.curves; c++) {
            CurveRange r = curves[c];
            float db = r.offsetDB;
            for (uint i = 0; i < r.count; i++) {
                Section q = sections[r.start + i];
                float num = q.n.x + phi * (q.n.y + phi * q.n.z);
                float den = q.d.x + phi * (q.d.y + phi * q.d.z);
                db += 10.0f * (precise::log10(max(num, 1e-30f)) - precise::log10(max(den, 1e-30f)));
            }
            table[c * p.columns + col] = db;
            if (r.combined != 0) combined += db;
        }
        table[p.combinedRow * p.columns + col] = combined;
    }

    struct Draw {
        float4 viewport; // width, height (points), backing scale, columns
        float4 color;    // straight RGBA
        float4 style;    // line width, opacity, fade distance from 0 dB (points, 0 = none)
        float4 map;      // dB at top, dB span, 0 dB y, table row
        float4 fill;     // lobe: opacity at the curve, unused, top and bottom y of its strip
    };
    struct VOut { float4 position [[position]]; float2 screen; float edge; float fade; };

    float4 clipPosition(float2 p, constant Draw &u) {
        return float4(p.x / u.viewport.x * 2 - 1, 1 - p.y / u.viewport.y * 2, 0, 1);
    }
    float curveY(float db, constant Draw &u) {
        if (!isfinite(db)) db = -400.0f;
        return clamp((u.map.x - db) / u.map.y * u.viewport.y, -2.0f * u.viewport.y, 3.0f * u.viewport.y);
    }
    float2 tablePoint(const device float *table, uint i, constant Draw &u) {
        uint columns = uint(u.viewport.w);
        float x = float(i) / float(max(columns, 2u) - 1) * u.viewport.x;
        return float2(x, curveY(table[uint(u.map.w) * columns + i], u));
    }
    float2 direction(float2 a, float2 b) {
        float2 d = b - a;
        return d * rsqrt(max(dot(d, d), 1e-12f));
    }

    vertex VOut peqStroke(uint vid [[vertex_id]], const device float *table [[buffer(0)]],
                          constant Draw &u [[buffer(1)]]) {
        uint last = uint(u.viewport.w) - 1;
        uint i = min(vid / 2, last);
        float2 p = tablePoint(table, i, u);
        float2 prev = tablePoint(table, i > 0 ? i - 1 : i, u);
        float2 next = tablePoint(table, min(i + 1, last), u);
        float2 before = i == 0 ? direction(p, next) : direction(prev, p);
        float2 after = i == last ? direction(prev, p) : direction(p, next);
        float2 n0(-before.y, before.x), n1(-after.y, after.x);
        float2 m = n0 + n1;
        m *= rsqrt(max(dot(m, m), 1e-12f));
        float join = min(2.0f, 1.0f / max(dot(m, n1), 0.001f));
        float edge = (vid % 2 ? 1.0f : -1.0f) * (u.style.x * 0.5f + 1.0f / u.viewport.z);
        float2 screen = p + m * edge * join;
        // A band's outline dissolves as it nears 0 dB, where the band does
        // nothing, so no band ever draws a baseline across the graph.
        float fade = u.style.z > 0 ? smoothstep(2.0f, u.style.z, abs(p.y - u.map.z)) : 1.0f;
        return {clipPosition(screen, u), screen, edge, fade};
    }
    fragment float4 peqStrokeColor(VOut in [[stage_in]], constant Draw &u [[buffer(1)]]) {
        float aa = 1.0f / u.viewport.z;
        float coverage = saturate((u.style.x * 0.5f - abs(in.edge)) / aa + 0.5f);
        float a = coverage * in.fade * u.style.y * u.color.a;
        return float4(u.color.rgb * a, a);
    }

    vertex VOut peqQuad(uint vid [[vertex_id]], constant Draw &u [[buffer(1)]]) {
        const float2 corners[] = {{0,0}, {1,0}, {0,1}, {1,1}};
        float2 screen = corners[vid] * u.viewport.xy;
        return {clipPosition(screen, u), screen, 0, 1};
    }

    // Only the strip of rows a band's lobe can reach, so a small bell costs
    // a thin sliver of fragments rather than the whole plot.
    vertex VOut peqLobeQuad(uint vid [[vertex_id]], constant Draw &u [[buffer(1)]]) {
        const float2 corners[] = {{0,0}, {1,0}, {0,1}, {1,1}};
        float2 c = corners[vid];
        float2 screen = float2(c.x * u.viewport.x, mix(u.fill.z, u.fill.w, c.y));
        return {clipPosition(screen, u), screen, 0, 1};
    }

    // The area between a band's own curve and 0 dB: strongest along the
    // curve and fading to nothing at 0 dB, antialiased along the curve.
    fragment float4 peqLobe(VOut in [[stage_in]], const device float *table [[buffer(0)]],
                            constant Draw &u [[buffer(1)]]) {
        uint columns = uint(u.viewport.w);
        uint row = uint(u.map.w) * columns;
        float fi = clamp(in.screen.x / u.viewport.x * float(columns - 1), 0.0f, float(columns - 1));
        uint i = min(uint(fi), columns - 2);
        float y0 = curveY(table[row + i], u), y1 = curveY(table[row + i + 1], u);
        float cy = mix(y0, y1, fi - float(i));
        float zero = u.map.z;
        float span = abs(cy - zero);
        if (span < 0.25f) discard_fragment();
        float side = cy < zero ? 1.0f : -1.0f;
        float insideCurve = (in.screen.y - cy) * side;
        float insideZero = (zero - in.screen.y) * side;
        float px = u.viewport.z;
        float coverage = saturate(insideCurve * px + 0.5f) * saturate(insideZero * px + 0.5f);
        if (coverage <= 0.0f) discard_fragment();
        float t = saturate(insideZero / span);
        // Fade by the curve's own distance from 0 dB too, or a band that
        // barely departs from flat leaves a thin tinted line along it.
        float a = u.fill.x * pow(t, 1.5f) * smoothstep(2.0f, 10.0f, span) * coverage * u.color.a;
        return float4(u.color.rgb * a, a);
    }

    fragment float4 peqComposite(VOut in [[stage_in]], constant Draw &u [[buffer(1)]],
                                 texture2d<float> source [[texture(0)]]) {
        constexpr sampler linearSampler(coord::normalized, address::clamp_to_zero, filter::linear);
        return source.sample(linearSampler, in.screen / u.viewport.xy) * u.style.y;
    }

    // Band dots: flat discs in the band's colour, antialiased analytically so
    // they stay crisp at any size or scale.
    struct Node { float2 center; float radius; float pad; float4 color; float4 state; };
    struct NodeOut { float4 position [[position]]; float2 local; uint instance [[flat]]; };

    vertex NodeOut peqNode(uint vid [[vertex_id]], uint iid [[instance_id]],
                           constant Node *nodes [[buffer(0)]], constant Draw &u [[buffer(1)]]) {
        Node n = nodes[iid];
        float extent = n.radius + 2.0f;
        const float2 corners[] = {{-1,-1}, {1,-1}, {-1,1}, {1,1}};
        float2 local = corners[vid] * extent;
        return {clipPosition(n.center + local, u), local, iid};
    }

    fragment float4 peqNodeColor(NodeOut in [[stage_in]], constant Node *nodes [[buffer(0)]],
                                 constant Draw &u [[buffer(1)]]) {
        Node n = nodes[in.instance];
        float aa = 0.6f / u.viewport.z;
        float a = (1.0f - smoothstep(n.radius - aa, n.radius + aa, length(in.local))) * n.state.z;
        return float4(n.color.rgb * a, a);
    }
    """
}
