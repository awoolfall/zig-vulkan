cbuffer vertex_buffer : register(b0)
{
    float4 quad_bounds;
}

cbuffer pixel_buffer : register(b1)
{
    float4 bg_colour;
    float4 border_colour;
    float2 quad_size_px;
    uint packed_corner_radii_px;
    float border_width_px;
    uint flags;
}

struct vs_out
{
    float4 position : SV_POSITION;
    float4 tex_coord : TEXCOORD;
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

    // top right corner radii
    float corner_radii = (packed_corner_radii_px >> (1*8)) & 0xff;
    if (uvpx.x > quad_size_px.x - corner_radii && uvpx.y > quad_size_px.y - corner_radii) {
        float2 uvpxro = px_from_border - float2(corner_radii, corner_radii);
        float d = corner_radii - distance(float2(corner_radii, corner_radii), px_from_border);
        px_from_border = float2(d, d);
        uvpxro = uvpxro * uvpxro;
        if (uvpxro.x + uvpxro.y > corner_radii*corner_radii) { discard; }
    }

    // top left corner radii
    corner_radii = (packed_corner_radii_px >> (0*8)) & 0xff;
    if (uvpx.x < corner_radii && uvpx.y > quad_size_px.y - corner_radii) {
        float2 uvpxro = px_from_border - float2(corner_radii, corner_radii);
        float d = corner_radii - distance(float2(corner_radii, corner_radii), px_from_border);
        px_from_border = float2(d, d);
        uvpxro = uvpxro * uvpxro;
        if (uvpxro.x + uvpxro.y > corner_radii*corner_radii) { discard; }
    }

    // bottom right corner radii
    corner_radii = (packed_corner_radii_px >> (3*8)) & 0xff;
    if (uvpx.x > quad_size_px.x - corner_radii && uvpx.y < corner_radii) {
        float2 uvpxro = px_from_border - float2(corner_radii, corner_radii);
        float d = corner_radii - distance(float2(corner_radii, corner_radii), px_from_border);
        px_from_border = float2(d, d);
        uvpxro = uvpxro * uvpxro;
        if (uvpxro.x + uvpxro.y > corner_radii*corner_radii) { discard; }
    }

    // bottom left corner radii
    corner_radii = (packed_corner_radii_px >> (2*8)) & 0xff;
    if (uvpx.x < corner_radii && uvpx.y < corner_radii) {
        float2 uvpxro = px_from_border - float2(corner_radii, corner_radii);
        float d = corner_radii - distance(float2(corner_radii, corner_radii), px_from_border);
        px_from_border = float2(d, d);
        uvpxro = uvpxro * uvpxro;
        if (uvpxro.x + uvpxro.y > corner_radii*corner_radii) { discard; }
    }

    float4 colour = bg_colour;

    // border
    if (px_from_border.x < border_width_px || px_from_border.y < border_width_px) {
        colour = colour * (1.0 - border_colour.a) + border_colour;
    }

    return colour;
}
