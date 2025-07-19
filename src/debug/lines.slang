struct CameraData
{
    float4x4 view;
    float4x4 projection;
};

[[vk::binding(0, 0)]]
ConstantBuffer<CameraData> camera_data : register(b0);

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
[shader("vertex")]
vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u); 
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float4x4 vp = mul(camera_data.view, camera_data.projection);

    float4 pos0_clip = mul(float4(input.pos0.xyz, 1.0), vp);
    float4 pos1_clip = mul(float4(input.pos1.xyz, 1.0), vp);

    float3 pos0 = (pos0_clip.xyz / pos0_clip.w);
    float3 pos1 = (pos1_clip.xyz / pos1_clip.w);

    float2 dir = pos1.xy - pos0.xy;
    float2 perp = normalize(dir.yx * float2(1.0, -1.0));
    perp.x *= (9.0 / 16.0);

    float line_width = 0.005;

    float2 clip_p = pos0.xy + (((x - 0.5) * perp * line_width) + (y * dir) + ((y - 0.5) * normalize(dir) * line_width));
    float clip_p_z = pos0.z + (pos1.z - pos0.z) * y;

    output.position = float4(clip_p, clip_p_z, 1.0) * pos0_clip.w;

    float uvx = 0.0 + (x * 1.0);
    float uvy = 0.0 + (y * 1.0);

    output.tex_coord = float4(uvx, uvy, 0.0, 0.0);

    output.colour = input.colour;

    return output;
}

[shader("pixel")]
float4 ps_main(vs_out input) : SV_Target
{
	return input.colour;
}

