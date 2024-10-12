cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
    float4 camera_position;
}

struct vs_in 
{
    float4 pos0 : TEXCOORD0;
    float4 pos1 : TEXCOORD1;
    float4 colour : COLOR0;
};

struct vs_out
{
    float4 position : SV_POSITION;
    float4 tex_coord : TEXCOORD;
    float4 colour : COLOR;
};

// generate quad in shader 
// from https://stackoverflow.com/questions/2588875/whats-the-best-way-to-draw-a-fullscreen-quad-in-opengl-3-2/51625078#51625078
vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u); 
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float4x4 vp = mul(view, projection);

    float4 pos0_clip = mul(input.pos0, vp);// mul(projection, mul(view, input.pos0));
    float4 pos1_clip = mul(input.pos1, vp);// mul(projection, mul(view, input.pos1));

    float2 pos0 = (pos0_clip.xy / pos0_clip.w);
    float2 pos1 = (pos1_clip.xy / pos1_clip.w);
    float2 mid_point = (pos0 + pos1) / 2.0;

    float line_height = length(pos1 - pos0);
    float line_width = 0.0025;

    float px = -(line_width / 2.0) + x * line_width;
    float py = -(line_height / 2.0) + y * line_height;
    float2 p = float2(px, py);

    float2 dir = normalize(pos1 - pos0);
    if (dir.x > 0.0) { dir = -dir; }
    float angle = acos(dot(dir, float2(0.0, 1.0)));

    float sin_angle = sin(angle);
    float cos_angle = cos(angle);
    float2x2 rotation_matrix = float2x2(cos_angle, -sin_angle, sin_angle, cos_angle);

    p = mul(rotation_matrix, p);
    p += mid_point;

    output.position = float4(p.x, p.y, 0.0, 1.0);

    float uvx = 0.0 + (x * 1.0);
    float uvy = 0.0 + (y * 1.0);

    output.tex_coord = float4(uvx, uvy, 0.0, 0.0);

    output.colour = input.colour;

    return output;
}

float4 ps_main(vs_out input) : SV_Target
{
	return input.colour;
}

