cbuffer vertex_buffer : register(b0)
{
    float4 quad_bounds;
}

cbuffer pixel_buffer : register(b1)
{
    float4 colour;
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
    return colour;
}
