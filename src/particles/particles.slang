struct vs_in 
{
    float4 position : Position;
    float4 colour: Colour;
    float4 velocity: Velocity;
    float4 scale: Scale;
};

struct vs_out
{
    float4 position : SV_POSITION;
    float2 uv: TEXCOORD0;
    float2 uv_scale: TEXCOORD1;
    float4 colour: Colour;
};

struct CameraData
{
    float4x4 view_matrix;
    float4x4 projection_matrix;
};
ConstantBuffer<CameraData> camera_data : register(b0);

struct PushConstants
{
    uint flags;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID, vs_in input)
{
    vs_out output = (vs_out) 0;

    float x = float(((uint(vertId) + 2u) / 3u)%2u);
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float4 p0 = input.position;
    float4 p1 = input.position;
    float3 up = float3(0.0, 1.0, 0.0);
    float3 right = float3(1.0, 0.0, 0.0);

    if (((push_constants.flags & 2) != 0) && length(input.velocity.xyz) > 0.0) {
        p0 = p0 + ((input.velocity * 0.5) * input.scale.y);
        p1 = p1 - ((input.velocity * 0.5) * input.scale.y);

        up = normalize(p1.xyz - p0.xyz);
        right = normalize(cross(float3(0.0, 0.0, 1.0), up));// up.yx * float2(1.0, -1.0);
    }

    p0 = mul(p0, camera_data.view_matrix);
    p1 = mul(p1, camera_data.view_matrix);

    float4 pos = lerp(p0, p1, y) + float4(up, 0.0) * (y - 0.5) * input.scale.y + float4(right, 0.0) * (x - 0.5) * input.scale.x;

    output.position = mul(pos, camera_data.projection_matrix);// mul(pos, mvp_noscale);
    output.uv = float2(x, y);
    output.uv = (output.uv - 0.5) * 2.0;

    float4 up_v = float4(0.0, 1.0, 0.0, 0.0);
    output.uv_scale = float2(1.0, length(up_v));

    output.colour = input.colour;

    return output;
}

[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    float distance = 0.0;
    float2 uv = input.uv;

    // is_circle
    if ((push_constants.flags & 1) != 0) {
        // if velocity aligned we want to extend the middle of the circle while keeping
        // the ends perfectly circular. Manipulate uvs to create this (saber-like) effect
        uv.y = (uv.y * input.uv_scale.y) - (uv.y / abs(uv.y)) * (input.uv_scale.y - 1.0);
        if ((uv.y * input.uv.y) < 0.0) {
            uv.y = 0.0;
        }

        distance = uv.x * uv.x + uv.y * uv.y;
        distance = sqrt(distance);
        distance = smoothstep(0.0, 1.00, distance);
    }

    return input.colour * float4(1.0, 1.0, 1.0, 1.0 - distance);
}

