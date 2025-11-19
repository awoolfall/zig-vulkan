struct VertexBuffer
{
    float4 quad_bounds;
};

struct PixelBuffer
{
    float4 background_colour;
    float4 border_colour;
    float4 packed_corner_radii_px;
    float4 packed_border_width_px;
    float2 quad_size_px;
    uint flags;
};


struct PushConstants
{
    uint32_t index;   
    float z_value;
};

[[vk::binding(0, 0)]]
ConstantBuffer<VertexBuffer[500]> vertex_buffer : register(b0);

[[vk::binding(1, 0)]]
ConstantBuffer<PixelBuffer[500]> pixel_buffer : register(b1);

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[[vk::binding(0, 1)]]
Texture2D quad_texture : t0;
[[vk::binding(1, 1)]]
SamplerState quad_sampler : s0;

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
[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID)
{
    VertexBuffer data = vertex_buffer[push_constants.index];

    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u); 
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    const float4 quad_bounds = data.quad_bounds;
    float px = quad_bounds.x + (x * (quad_bounds.z - quad_bounds.x));
    float py = quad_bounds.y + (y * (quad_bounds.w - quad_bounds.y));

    output.position = float4(px, py, push_constants.z_value, 1.0);

    float uvx = x;
    float uvy = y;

    output.tex_coord = float4(uvx, uvy, 0.0, 0.0);

    return output;
}

[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    PixelBuffer data = pixel_buffer[push_constants.index];

    float2 uvpx = input.tex_coord.xy * data.quad_size_px;
    float2 px_from_border = (0.5 - abs(input.tex_coord.xy - 0.5)) * data.quad_size_px;
    // center of a pixel is 0.5, therefore need to bias by 0.5
    px_from_border += 0.5;

    float2 quad = float2((input.tex_coord > 0.5).xy);

    // calculate pixels from border with corner radii
    float2 cuv_dir = (quad - 0.5) * 2.0;
    int cell = int(quad.x) + (2 * int(quad.y));
    float corner_radius = unpack(data.packed_corner_radii_px, cell);

    float2 corner_origin = (saturate(cuv_dir) * data.quad_size_px) - (corner_radius * cuv_dir);
    float2 c_px = uvpx - corner_origin;
    float2 c_uv = saturate((c_px / corner_radius) * cuv_dir);

    float2 c_uv2 = c_uv * c_uv;
    float2 b = 1.0 - float2(sqrt(1.0 - c_uv2.y), sqrt(1.0 - c_uv2.x));
    px_from_border -= (b * corner_radius);
    float2 d = b - c_uv;

    float min_px_from_border = min(px_from_border.x, px_from_border.y);
    // cull if outside of quad
    if (min_px_from_border <= 0.0) { discard; }

    // background colour
    float4 colour = data.background_colour;

    // add texture colour before borders
    bool has_texture = ((data.flags >> 0) & 1) != 0;
    if (has_texture) {
        float4 texture_colour = quad_texture.Sample(quad_sampler, input.tex_coord.xy);
        colour = float4(colour.rgb * (1 - texture_colour.a) + texture_colour.rgb * texture_colour.a, colour.a);
    }

    // border colour
    float2 bw = float2(
        unpack(data.packed_border_width_px, int(quad.x)),
        unpack(data.packed_border_width_px, 2 + int(quad.y))
    );
    float2 ba = saturate(bw - px_from_border + saturate(px_from_border));
    float border_alpha = max(ba.x, ba.y);

    colour = colour * (1.0 - data.border_colour.a * border_alpha) + data.border_colour * border_alpha;

    // corner anti-aliasing
    colour.a *= saturate(min_px_from_border);

    return float4(colour.rgb * colour.a, colour.a);
}
