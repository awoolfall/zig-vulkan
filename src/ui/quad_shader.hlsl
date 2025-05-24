cbuffer vertex_buffer : register(b0)
{
    float4 quad_bounds;
}

cbuffer pixel_buffer : register(b1)
{
    float4 background_colour;
    float4 border_colour;
    float2 quad_size_px;
    uint packed_corner_radii_px;
    uint packed_border_width_px;
    uint flags;
}

Texture2D quad_texture;
SamplerState quad_sampler;

inline uint unpack(uint packed_value, uint position)
{
    return (packed_value >> (position * 8)) & 0xff;
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

float4 ps_main(vs_out input) : SV_TARGET
{
    float2 uvpx = input.tex_coord.xy * quad_size_px;
    float2 px_from_border = (0.5 - abs(input.tex_coord.xy - 0.5)) * quad_size_px;
    // center of a pixel is 0.5, therefore need to bias by 0.5
    px_from_border += 0.5;

    // calculate pixels from border with corner radii
    {
        float2 cuv_dir = float2(1.0, 1.0);
        float corner_radius = 0.0;

        if (input.tex_coord.x > 0.5 && input.tex_coord.y > 0.5) {
            // top right corner
            corner_radius = unpack(packed_corner_radii_px, 1);
            cuv_dir = float2(1.0, 1.0);
        }
        else if (input.tex_coord.x < 0.5 && input.tex_coord.y > 0.5) {
            // top left corner
            corner_radius = unpack(packed_corner_radii_px, 0);
            cuv_dir = float2(-1.0, 1.0);
        }
        else if (input.tex_coord.x > 0.5 && input.tex_coord.y < 0.5) {
            // bottom right corner
            corner_radius = unpack(packed_corner_radii_px, 3);
            cuv_dir = float2(1.0, -1.0);
        }
        else if (input.tex_coord.x < 0.5 && input.tex_coord.y < 0.5) {
            // bottom left corner
            corner_radius = unpack(packed_corner_radii_px, 2);
            cuv_dir = float2(-1.0, -1.0);
        }

        if (corner_radius > 0.0) {
            float2 corner_origin = (saturate(cuv_dir) * quad_size_px) - (corner_radius * cuv_dir);
            float2 px = uvpx - corner_origin;
            float2 cuv = saturate((px / corner_radius) * cuv_dir);

            float2 cuv2 = cuv * cuv;
            float2 b = float2(sqrt(1.0 - cuv2.y), sqrt(1.0 - cuv2.x));
            float2 d = b - cuv;
            if ((cuv.x * cuv.y) != 0.0) {
                px_from_border = min(px_from_border, (d * corner_radius) + 0.5);
            }
        }
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
    float2 uv = input.tex_coord - 0.5;
    float2 border_widths;
    if (uv.x < 0.0) {
        border_widths.x = unpack(packed_border_width_px, 0);
    }
    if (uv.x > 0.0) {
        border_widths.x = unpack(packed_border_width_px, 1);
    }
    if (uv.y > 0.0) {
        border_widths.y = unpack(packed_border_width_px, 2);
    }
    if (uv.y < 0.0) {
        border_widths.y = unpack(packed_border_width_px, 3);
    }

    float2 border_alphas = saturate(border_widths - px_from_border + 1.0);
    float border_alpha = max(border_alphas.x, border_alphas.y);
    colour = colour * (1.0 - border_colour.a * border_alpha) + border_colour * border_alpha;

    // corner anti-aliasing
    colour.a *= saturate(min_px_from_border);

    return float4(colour.rgb * colour.a, colour.a);
}
