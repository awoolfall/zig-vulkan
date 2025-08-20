
// burley diffuse
float calculate_diffuse(float3 light_vector, float3 view_vector, float3 normal_vector, float roughness)
{
    light_vector = normalize(light_vector);
    view_vector = normalize(view_vector);
    normal_vector = normalize(normal_vector);

    float cos_theta_l = saturate(dot(normal_vector, light_vector));
    float cos_theta_v = saturate(dot(normal_vector, view_vector));

    float3 half_vector = normalize(light_vector + view_vector);
    float cos_theta_d = saturate(dot(light_vector, half_vector));

    float FD90 = 0.5 + (2.0 * roughness * cos_theta_d * cos_theta_d);
    return 
        cos_theta_l *
        (1.0 / 3.14159) * 
        (1.0 + (FD90 - 1.0) * pow((1.0 - cos_theta_l), 5)) * 
        (1.0 + (FD90 - 1.0) * pow((1.0 - cos_theta_v), 5));
}

struct LightData
{
    float4 position;
    float4 direction;
    float4 colour;
    float intensity;
    float umbra;
    float penumbra;
    uint type;
};
#define LIGHT_TYPE_DIRECTIONAL 0
#define LIGHT_TYPE_POINT 1
#define LIGHT_TYPE_SPOT 2

float3 calculate_light_diffuse(
    LightData light,
    float3 view_direction,
    float3 fragment_world_pos,
    float3 fragment_normal,
    float fragment_roughness
) {
    if (light.intensity < 0.05) { return float3(0.0, 0.0, 0.0); }

    float3 light_dir;
    float3 light_colour;

    // TODO: distance max, smoothstep to zero, cull lights
    if (light.type == LIGHT_TYPE_DIRECTIONAL) {
        light_colour = light.colour.rgb * light.intensity;
        light_dir = light.direction.xyz;
    }
    else if (light.type == LIGHT_TYPE_POINT) {
        light_dir = normalize(light.position.xyz - fragment_world_pos);

        float dist = length(light.position.xyz - fragment_world_pos);
        dist = max(dist, 0.01);
        float attenuation = (light.intensity * light.intensity) / (dist * dist);
        light_colour = light.colour.rgb * attenuation;
    }
    else if (light.type == LIGHT_TYPE_SPOT) {
        light_dir = normalize(light.position.xyz - fragment_world_pos);

        float dist = length(light.position.xyz - fragment_world_pos);
        float attenuation = (light.intensity * light.intensity) / (dist * dist);

        float ts = dot(light_dir, normalize(light.direction.xyz));
        float tu = cos(light.umbra);
        float t = saturate((ts - tu) / (cos(light.umbra - light.penumbra) - tu));
        float fdir = t * t;

        light_colour = light.colour.rgb * fdir * attenuation;
    } else {
        return float3(0.0, 0.0, 0.0);
    }

    float light_diffuse = calculate_diffuse(
        light_dir,
        view_direction,
        fragment_normal,
        fragment_roughness
    );

    return light_colour.rgb * light_diffuse;
}

