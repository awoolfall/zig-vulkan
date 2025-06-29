struct Bounds {
    float left;
    float bottom;
    float right;
    float top;
};

struct FontTextProps {
    float2 msdf_unit_range;
    float4 fg_colour;
    float4 bg_colour;
};
ConstantBuffer<FontTextProps[1024]> font_text_props : register(b0);

struct PushConstants
{
    uint32_t index;   
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[[vk::binding(0, 1)]]
Texture2D msdf_font_texture;
[[vk::binding(1, 1)]]
SamplerState msdf_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 tex_coord : TEXCOORD0;
};

// generate quad in shader 
// from https://stackoverflow.com/questions/2588875/whats-the-best-way-to-draw-a-fullscreen-quad-in-opengl-3-2/51625078#51625078
[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID, float4 quad_bounds : TEXCOORD0, float4 atlas_bounds : TEXCOORD1)
{
    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u); 
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float px = quad_bounds.x + (x * (quad_bounds.z - quad_bounds.x));
    float py = quad_bounds.y + (y * (quad_bounds.w - quad_bounds.y));

    output.position = float4(px, py, 0.0, 1.0);

    float uvx = atlas_bounds.x + (x * (atlas_bounds.z - atlas_bounds.x));
    float uvy = atlas_bounds.y + (y * (atlas_bounds.w - atlas_bounds.y));

    output.tex_coord = float4(uvx, uvy, 0.0, 0.0);

    return output;
}


float median(float r, float g, float b) {
    return max(min(r, g), min(max(r, g), b));
}

float screenPxRange(float2 uvCoord) {
    float2 screenTexSize = float2(1.0, 1.0)/fwidth(uvCoord);
    return max(0.5*dot(font_text_props[0].msdf_unit_range, screenTexSize), 1.0);
}

// converted from https://github.com/Chlumsky/msdfgen
[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    FontTextProps props = font_text_props[push_constants.index];

    float4 msd = msdf_font_texture.Sample(msdf_sampler, input.tex_coord.xy);
    float sd = median(msd.r, msd.g, msd.b);
    float screenPxDistance = screenPxRange(input.tex_coord.xy) * (sd - 0.5);
    float opacity = clamp(screenPxDistance + 0.5, 0.0, 1.0);
    //return msd;
    float4 colour = lerp(props.bg_colour, props.fg_colour, opacity);
    return float4(colour.rgb * colour.a, colour.a);
}
