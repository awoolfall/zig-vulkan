struct vs_in 
{
    float4 rowX : RowX;
    float4 rowY : RowY;
    float4 rowZ : RowZ;
    float4 rowW : RowW;
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

cbuffer camera_constant_buffer: register(b0)
{
    row_major float4x4 v_matrix;
    row_major float4x4 p_matrix;
    uint flags;
}

[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID, vs_in input)
{
    vs_out output = (vs_out) 0;
    float4x4 model_matrix = float4x4(input.rowX, input.rowY, input.rowZ, input.rowW);

    float x = float(((uint(vertId) + 2u) / 3u)%2u);
    float y = float(((uint(vertId) + 1u) / 3u)%2u);

    float4x4 vp = mul(v_matrix, p_matrix);
    float4x4 mv = mul(model_matrix, v_matrix);
    float4x4 mv_noscale = mv;
    mv_noscale[0] = float4(1.0, 0.0, 0.0, mv[0][3]);
    mv_noscale[1] = float4(0.0, 1.0, 0.0, mv[1][3]);
    mv_noscale[2] = float4(0.0, 0.0, 1.0, mv[2][3]);
    float4x4 mvp = mul(mv, p_matrix);
    float4x4 mvp_noscale = mul(mv_noscale, p_matrix);

    float4 right_v = float4(1.0, 0.0, 0.0, 0.0);
    float4 up_v = float4(0.0, 1.0, 0.0, 0.0);
    if ((flags & 2) && length(input.velocity.xyz) > 0.0) {
        float4 cam_vel = mul(input.velocity, mvp);
        cam_vel = float4(cam_vel.xyz, 0.0) + float4(normalize(cam_vel.xyz), 0.0);
        right_v = normalize(float4(cross(normalize(cam_vel.xyz), float3(0.0, 0.0, 1.0)), 0.0));
        up_v = cam_vel;

        float4 p0 = input.rowW + (input.velocity * 0.5);
        p0 = mul(vp, p0);
        float4 p1 = input.rowW + (input.velocity * -0.5);
        p1 = mul(vp, p1);
        up_v = float4(normalize(p1.xy - p0.xy), 0.0, 0.0);
        right_v = up_v.yxzw * float4(1.0, -1.0, 1.0, 1.0);
        up_v = up_v * length(input.velocity) * (1.0 - dot(p1.xyz - p0.xyz, float3(0.0, 0.0, 1.0)));
    }
    float4 pos = right_v * (x - 0.5) + up_v * (y - 0.5);
    pos.w = 1.0;

    float4 p0 = input.rowW;
    float4 p1 = input.rowW;
    float3 up = float3(0.0, 1.0, 0.0);
    float3 right = float3(1.0, 0.0, 0.0);

    if ((flags & 2) && length(input.velocity.xyz) > 0.0) {
        p0 = p0 + ((input.velocity * 0.5) * input.scale.y);
        p1 = p1 - ((input.velocity * 0.5) * input.scale.y);

        up = normalize(p1.xyz - p0.xyz);
        right = normalize(cross(float3(0.0, 0.0, 1.0), up));// up.yx * float2(1.0, -1.0);
    }

    p0 = mul(p0, v_matrix);
    p1 = mul(p1, v_matrix);

    pos = lerp(p0, p1, y) + float4(up, 0.0) * (y - 0.5) * input.scale.y + float4(right, 0.0) * (x - 0.5) * input.scale.x;

    output.position = mul(pos, p_matrix);// mul(pos, mvp_noscale);
    output.uv = float2(x, y);
    output.uv = (output.uv - 0.5) * 2.0;
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
    if (flags & 1) {
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

