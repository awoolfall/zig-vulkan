cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

cbuffer instance_data : register(b1)
{
    row_major float4x4 model_matrix;
}

struct vs_in
{
    float3 pos : POS;
    float3 normals : NORMAL;
    float2 tex_coord : TEXCOORD;
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
    float4x4 mvp = mul(model_matrix, vp);
    output.position = mul(float4(input.pos, 1.0), mvp);
    float4 colour = float4(vertId == 0, vertId == 1, vertId == 2, 1.0);
    float4x4 model_rotation_matrix = float4x4(
        float4(model_matrix[0].xyz, 0.0),
        float4(model_matrix[1].xyz, 0.0),
        float4(model_matrix[2].xyz, 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );
    output.colour = mul(float4(input.normals, 0.0), model_rotation_matrix);
    return output;
}

float4 ps_main(vs_out input) : SV_TARGET
{
    return (((input.colour / 2.0) + 0.5) / 2.0) + 0.5;
}
