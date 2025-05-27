cbuffer vertex_buffer : register(b0)
{
    float4 quad_bounds;
}

cbuffer pixel_buffer : register(b1)
{
    float4 background_colour;
    float4 border_colour;
    float4 packed_corner_radii_px;
    float4 packed_border_width_px;
    float2 quad_size_px;
    uint flags;
}

Texture2D quad_texture;
SamplerState quad_sampler;

inline float unpack(float4 packed_value, uint position)
{
    return packed_value[position];
}

struct vs_out
{
    float4 position : SV_POSITION;
    float4 tex_coord : TEXCOORD0;
};

// generate quad in shader 
// from https://stackoverflow.com/questions/2588875/whats-the-best-way-to-draw-a-fullscreen-quad-in-opengl-3-2/51625078#51625078
vs_out vs_main(uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u); 
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float px = quad_bounds.x + (x * (quad_bounds.z - quad_bounds.x));
    float py = quad_bounds.y + (y * (quad_bounds.w - quad_bounds.y));

    output.position = float4(px, py, 0.0, 1.0);

    float uvx = x;
    float uvy = y;

    output.tex_coord = float4(uvx, uvy, 0.0, 0.0);

    return output;
}

float ease_sin(float x) {
    return -(cos(3.14159 * x) - 1.0) / 2.0;
}

float4 ps_main(vs_out input) : SV_TARGET
{
    float2 uvpx = input.tex_coord.xy * quad_size_px;
    float2 px_from_border = (0.5 - abs(input.tex_coord.xy - 0.5)) * quad_size_px;
    // center of a pixel is 0.5, therefore need to bias by 0.5
    px_from_border += 0.5;

    float2 quad = input.tex_coord > 0.5;

    // calculate pixels from border with corner radii
    float2 cuv_dir = (quad - 0.5) * 2.0;
    int cell = quad.x + (2 * quad.y);
    float corner_radius = unpack(packed_corner_radii_px, cell);

    float2 corner_origin = (saturate(cuv_dir) * quad_size_px) - (corner_radius * cuv_dir);
    float2 c_px = uvpx - corner_origin;
    float2 c_uv = saturate((c_px / corner_radius) * cuv_dir);

    //float2 c_uv2 = c_uv * c_uv;
    //float2 b = float2(sqrt(1.0 - c_uv2.y), sqrt(1.0 - c_uv2.x));
    //float2 d = b - c_uv;
    if ((c_uv.x * c_uv.y) != 0.0) {
        //px_from_border = min(px_from_border, (d * corner_radius) + 0.5);
        px_from_border.x = (1.0 - length(c_uv)) * corner_radius + 0.5;
        px_from_border.y = px_from_border.x;
    }

    float min_px_from_border = min(px_from_border.x, px_from_border.y);
    // cull if outside of quad
    if (min_px_from_border <= 0.0) { discard; }

    // background colour
    float4 colour = background_colour;

    // add texture colour before borders
    bool has_texture = (flags >> 0) & 1;
    if (has_texture) {
        float4 texture_colour = quad_texture.Sample(quad_sampler, input.tex_coord.xy);
        colour = float4(colour.rgb * (1 - texture_colour.a) + texture_colour.rgb * texture_colour.a, colour.a);
    }

    // border colour
    float2 bw = float2(
        unpack(packed_border_width_px, quad.x),
        unpack(packed_border_width_px, 2 + quad.y)
    );
    float angle = atan2(c_uv.y, c_uv.x);
    float perc = 1.0 - (angle / 1.5707);

    float2 border_widths = bw;
    if ((c_uv.x * c_uv.y) != 0.0) {
        float bwa = bw.x * ease_sin(perc) + bw.y * (1.0 - ease_sin(perc));
        border_widths = float2(bwa, bwa);
    }
    float2 border_alphas = saturate(border_widths - px_from_border + saturate(px_from_border));
    float border_alpha = max(border_alphas.x, border_alphas.y);

    colour = colour * (1.0 - border_colour.a * border_alpha) + border_colour * border_alpha;

    // corner anti-aliasing
    colour.a *= saturate(min_px_from_border);

    return float4(colour.rgb * colour.a, colour.a);
}
