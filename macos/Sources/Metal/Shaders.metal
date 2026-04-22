#include <metal_stdlib>
using namespace metal;

// Two pipelines:
//   bg_vertex/bg_fragment  — one instance per cell, draws bg rect.
//   text_vertex/text_fragment — one instance per glyph-bearing cell,
//                                draws a tight quad at glyph bearings and
//                                alpha-blends fg over the existing bg.

struct Uniforms {
    float2 viewportSize; // drawable size in pixels
    float2 cellSize;     // pixels per cell
};

constant float2 kCorner[6] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(1, 0), float2(1, 1), float2(0, 1),
};

static inline float2 toNDC(float2 px, float2 vp) {
    float2 ndc;
    ndc.x =  (px.x / vp.x) * 2.0 - 1.0;
    ndc.y = -((px.y / vp.y) * 2.0 - 1.0);
    return ndc;
}

//------------------------------------------------------------------ BG

struct BgInstance {
    ushort2 gridPos;   // (col, row)
    uchar4  color;     // RGBA
};

struct BgVertexOut {
    float4 position [[position]];
    float4 color [[flat]];
};

vertex BgVertexOut bg_vertex(uint vid [[vertex_id]],
                              uint iid [[instance_id]],
                              constant BgInstance *bg [[buffer(0)]],
                              constant Uniforms &u [[buffer(1)]])
{
    BgInstance i = bg[iid];
    float2 corner = kCorner[vid];
    float2 px = float2(i.gridPos) * u.cellSize + corner * u.cellSize;

    BgVertexOut o;
    o.position = float4(toNDC(px, u.viewportSize), 0, 1);
    o.color = float4(i.color) / 255.0;
    return o;
}

fragment float4 bg_fragment(BgVertexOut in [[stage_in]]) {
    return in.color;
}

//------------------------------------------------------------------ TEXT

struct TextInstance {
    ushort2 gridPos;
    short2  offset;     // pixels from cell top-left to glyph top-left
    ushort2 glyphSize;  // pixels
    float2  uvOrigin;   // normalized atlas UV
    float2  uvSize;
    uchar4  fg;         // RGBA (alpha used for blending curve; 255 = opaque)
};

struct TextVertexOut {
    float4 position [[position]];
    float2 uv;
    float4 fg [[flat]];
};

vertex TextVertexOut text_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant TextInstance *ts [[buffer(0)]],
                                  constant Uniforms &u [[buffer(1)]])
{
    TextInstance i = ts[iid];
    float2 corner = kCorner[vid];
    float2 cellOrigin = float2(i.gridPos) * u.cellSize;
    float2 px = cellOrigin + float2(i.offset) + corner * float2(i.glyphSize);

    TextVertexOut o;
    o.position = float4(toNDC(px, u.viewportSize), 0, 1);
    o.uv = i.uvOrigin + i.uvSize * corner;
    o.fg = float4(i.fg) / 255.0;
    return o;
}

fragment float4 text_fragment(TextVertexOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]],
                               sampler atlasSampler [[sampler(0)]])
{
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    // Unpremultiplied fragment; pipeline does sourceAlpha/oneMinusSourceAlpha.
    return float4(in.fg.rgb, coverage * in.fg.a);
}

//------------------------------------------------------------------ CURSOR
// Sub-cell-positioned filled rect. Used to draw peer cursor borders as four
// thin strips around a cell (top, bottom, left, right). Blends over the text
// pass so borders read clearly without occluding the glyph.

struct CursorInstance {
    ushort2 gridPos;
    float2  originFrac;  // (0..1) cell-space origin
    float2  sizeFrac;    // (0..1) cell-space size
    uchar4  color;
};

struct CursorVertexOut {
    float4 position [[position]];
    float4 color [[flat]];
};

vertex CursorVertexOut cursor_vertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      constant CursorInstance *cs [[buffer(0)]],
                                      constant Uniforms &u [[buffer(1)]])
{
    CursorInstance i = cs[iid];
    float2 corner = kCorner[vid];
    float2 cellOrigin = float2(i.gridPos) * u.cellSize;
    float2 px = cellOrigin + i.originFrac * u.cellSize + corner * i.sizeFrac * u.cellSize;

    CursorVertexOut o;
    o.position = float4(toNDC(px, u.viewportSize), 0, 1);
    o.color = float4(i.color) / 255.0;
    return o;
}

fragment float4 cursor_fragment(CursorVertexOut in [[stage_in]]) {
    return in.color;
}
