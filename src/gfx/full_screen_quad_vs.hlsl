struct vs_out
{
    float4 position : SV_POSITION;
    float2 uv: TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID)
{
    vs_out output = (vs_out) 0;
    float x = float(((uint(vertId) + 2u) / 3u)%2u) * 2.0 - 1.0; 
    float y = float(((uint(vertId) + 1u) / 3u)%2u) * 2.0 - 1.0;

    output.position = float4(x, y, 0.0, 1.0);
    output.uv = float2(x, -y);
    output.uv = (output.uv / 2.0) + 0.5;

    return output;
}
