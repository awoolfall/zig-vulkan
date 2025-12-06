
struct PushConstants
{
    float4x4 vp;
    float4x4 model_colour_pack_matrix;
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
    float3 normals : NORMAL;
    float2 tex_coord : TEXCOORD;
};

[shader("vertex")]
vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out)0;

    float4x4 model = push_constants.model_colour_pack_matrix;
    float4 colour = float4(model._14, model._24, model._34, 1.0);
    model._14 = 0.0;
    model._24 = 0.0;
    model._34 = 0.0;

    float4x4 mvp = mul(model, push_constants.vp);
    output.position = mul(float4(input.pos, 1.0), mvp);
    output.colour = float4(input.color.rgb * colour.rgb, 1.0);
    output.normals = input.normals;
    output.tex_coord = input.tex_coord;
    return output;
}

[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    return float4(input.colour.rgb, 0.03);
}
