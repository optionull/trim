/// The grid's Metal shaders, compiled from source when the renderer starts, so the app needs no metallib.
///
/// Two instanced passes, each a four-vertex strip per instance: rects (backgrounds, the cursor, and decorations, with
/// the curly underline worked out in the fragment shader) and glyphs (sampled from the coverage atlas and coloured, or
/// from the colour atlas as they are). Positions are in pixels from the top left; output is premultiplied.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 viewport;
    };

    // Kinds of rect: a fill, or a decoration drawn in its band.
    constant uint kindFill = 0;
    constant uint kindUnderline = 1;
    constant uint kindUndercurl = 2;
    constant uint kindDotted = 3;
    constant uint kindDashed = 4;
    constant uint kindBorder = 5;
    constant uint kindCardTop = 6;
    constant uint kindCardMiddle = 7;
    constant uint kindCardBottom = 8;

    struct RectInstance {
        float2 origin;
        float2 size;
        float4 color;
        uint kind;
        float thickness;
    };

    struct GlyphInstance {
        float2 origin;
        float2 size;
        float2 atlasOrigin;
        float2 atlasSize;
        float4 color;
        uint colored;
    };

    constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

    static float4 clipPosition(float2 pixel, float2 viewport) {
        return float4(pixel.x / viewport.x * 2.0 - 1.0, 1.0 - pixel.y / viewport.y * 2.0, 0.0, 1.0);
    }

    struct RectOut {
        float4 position [[position]];
        float4 color;
        float2 local;
        float2 size;
        uint kind [[flat]];
        float thickness;
    };

    vertex RectOut rect_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device RectInstance *rects [[buffer(0)]],
                               constant Uniforms &uniforms [[buffer(1)]]) {
        RectInstance rect = rects[iid];
        float2 corner = corners[vid];
        RectOut out;
        out.position = clipPosition(rect.origin + corner * rect.size, uniforms.viewport);
        out.color = rect.color;
        out.local = corner * rect.size;
        out.size = rect.size;
        out.kind = rect.kind;
        out.thickness = rect.thickness;
        return out;
    }

    fragment float4 rect_fragment(RectOut in [[stage_in]]) {
        float alpha = in.color.a;
        if (in.kind == kindUndercurl) {
            // A sine wave across the band, one period per two band heights, antialiased by distance.
            float half_band = in.size.y * 0.5;
            float amplitude = max(half_band - in.thickness * 0.5, 0.0);
            float period = max(in.size.y * 2.0, 4.0);
            float centre = half_band + amplitude * sin(in.local.x / period * 2.0 * M_PI_F);
            float distance = abs(in.local.y - centre);
            alpha *= clamp(in.thickness * 0.5 - distance + 0.5, 0.0, 1.0);
        } else if (in.kind == kindDotted) {
            // Dots as wide as the line is thick, a dot's width apart.
            alpha *= step(fmod(in.local.x, in.thickness * 2.0), in.thickness);
        } else if (in.kind >= kindCardTop && in.kind <= kindCardBottom) {
            // A row of a sunken, rounded block: `thickness` is the device pixels to a point. Corners are rounded at the
            // block's top (first row) and bottom (last); the fill is shaded darker along its top and sides, and the bottom
            // edge has a faint lip, so it reads as set into the page.
            float u = in.thickness;
            float radius = 8.0 * u;
            float2 half_size = in.size * 0.5;
            float2 p = in.local - half_size;
            float2 q = abs(p) - (half_size - radius);
            float rounded = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
            float2 sq = abs(p) - half_size;
            float square = max(sq.x, sq.y);
            bool top = in.kind == kindCardTop;
            bool bottom = in.kind == kindCardBottom;
            float d = ((!top && p.y < 0.0) || (!bottom && p.y > 0.0)) ? square : rounded;
            float coverage = clamp(0.5 - d, 0.0, 1.0);
            float side = min(in.local.x, in.size.x - in.local.x);
            float shade = 0.22 * clamp(1.0 - side / (5.0 * u), 0.0, 1.0);
            if (top) { shade = max(shade, 0.42 * clamp(1.0 - in.local.y / (10.0 * u), 0.0, 1.0)); }
            float3 rgb = in.color.rgb * (1.0 - shade);
            if (bottom) {
                float lip = clamp(1.0 - (in.size.y - in.local.y) / (1.5 * u), 0.0, 1.0);
                rgb = mix(rgb, float3(1.0), 0.08 * lip);
            }
            return float4(rgb * coverage, coverage);
        } else if (in.kind == kindBorder) {
            // A rounded outline just inside the rect: the distance to its edge, kept to a band `thickness` wide.
            float radius = min(in.size.y * 0.3, in.size.x * 0.5);
            float2 p = abs(in.local - in.size * 0.5) - (in.size * 0.5 - radius);
            float inside = radius - (length(max(p, 0.0)) + min(max(p.x, p.y), 0.0));
            alpha *= clamp(in.thickness * 0.5 - abs(inside - in.thickness * 0.5) + 0.5, 0.0, 1.0);
        } else if (in.kind == kindDashed) {
            // Dashes three thicknesses long, two apart.
            float dash = max(in.thickness * 3.0, 3.0);
            alpha *= step(fmod(in.local.x, dash + max(in.thickness * 2.0, 2.0)), dash);
        }
        return float4(in.color.rgb * alpha, alpha);
    }

    struct GlyphOut {
        float4 position [[position]];
        float4 color;
        float2 atlas;
        uint colored [[flat]];
    };

    vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device GlyphInstance *glyphs [[buffer(0)]],
                                 constant Uniforms &uniforms [[buffer(1)]]) {
        GlyphInstance glyph = glyphs[iid];
        float2 corner = corners[vid];
        GlyphOut out;
        out.position = clipPosition(glyph.origin + corner * glyph.size, uniforms.viewport);
        out.color = glyph.color;
        out.atlas = glyph.atlasOrigin + corner * glyph.atlasSize;
        out.colored = glyph.colored;
        return out;
    }

    fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                                   texture2d<float> coverage [[texture(0)]],
                                   texture2d<float> colors [[texture(1)]]) {
        constexpr sampler pixels(coord::pixel, filter::nearest, address::clamp_to_zero);
        if (in.colored != 0) {
            return colors.sample(pixels, in.atlas);
        }
        float alpha = coverage.sample(pixels, in.atlas).r * in.color.a;
        return float4(in.color.rgb * alpha, alpha);
    }
    """
}
