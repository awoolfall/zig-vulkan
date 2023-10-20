cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

struct vs_in
{
    float3 pos : POS;
};

struct vs_out
{
    float4 position : SV_POSITION;
    float4 colour : POS;
};

vs_out vs_main(vs_in input, uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;
    float4x4 vp = mul(view, projection);
    output.position = mul(float4(input.pos, 1.0), vp);
    float4 colour = float4(vertId == 0, vertId == 1, vertId == 2, 1.0);
    output.colour = colour;
    return output;
}

float4 ps_main(vs_out input) : SV_TARGET
{
    return input.colour;
}
