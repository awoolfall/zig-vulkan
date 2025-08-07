
struct PushConstants
{
    float4x4 vp;
    float4x4 model_matrix;
    float4 colour;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

struct vs_in
{
    float3 pos : POS;
    float3 normals : NORMAL;
    float2 tex_coord : TEXCOORD;
    float3 color: COLOR;
};

struct vs_out
{
    float4 position : SV_POSITION;
    float4 colour : POS;
};

[shader("vertex")]
vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out) 0;
    float4x4 mvp = mul(push_constants.model_matrix, push_constants.vp);
    output.position = mul(float4(input.pos, 1.0), mvp);
    output.colour = float4(input.color * push_constants.colour.rgb, 1.0);
    return output;
}

[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    return float4(input.colour.rgb, 1.0);
}
