

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

#define PI 3.14159

// burley diffuse
float calculate_burley_diffuse(float3 light_vector, float3 view_vector, float3 normal_vector, float roughness)
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

// GGX specular
float D_GGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    return a2 / (PI * denom * denom);
}

float3 F_Schlick(float VdotH, float3 F0) {
    return F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);
}

float G_SchlickGGX(float NdotV, float roughness) {
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

float G_Smith(float NdotV, float NdotL, float roughness) {
    float ggx2 = G_SchlickGGX(NdotV, roughness);
    float ggx1 = G_SchlickGGX(NdotL, roughness);
    return ggx1 * ggx2;
}

float3 calculate_ggx_specular(float3 normalVector, float3 viewVector, float3 lightVector, float3 baseReflectivity, float roughness) {
    float3 halfwayVector = normalize(viewVector + lightVector);

    float normalDotView = max(dot(normalVector, viewVector), 0.0001);
    float normalDotLight = max(dot(normalVector, lightVector), 0.0001);
    float normalDotHalfway = max(dot(normalVector, halfwayVector), 0.0);
    float viewDotHalfway = max(dot(viewVector, halfwayVector), 0.0);

    float distribution = D_GGX(normalDotHalfway, roughness);
    float3 fresnel = F_Schlick(viewDotHalfway, baseReflectivity);
    float geometry = G_Smith(normalDotView, normalDotLight, roughness);

    return (distribution * fresnel * geometry) / (4.0 * normalDotLight * normalDotView);
}

float3 calculate_blinn_phong_specular(float3 light_dir, float3 view_vector, float3 normal_vector)
{
    float3 dd = normalize(light_dir + view_vector);
    float s = pow(max(dot(dd, normal_vector), 0.0), 32.0);
    return float3(s, s, s);
}

float3 calculate_light_contribution(LightData light, float3 fragment_albedo, float3 view_vector, float3 fragment_world_pos, float3 normal_vector, float reflectivity, float roughness)
{
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

    float3 specular = calculate_ggx_specular(normal_vector, view_vector, light_dir, reflectivity, roughness);
    // float3 specular = calculate_blinn_phong_specular(light_dir, view_vector, normal_vector);
    //float3 specular = CalculateSpecularBeckmann(normal_vector, view_vector, light_dir, reflectivity, roughness);
    specular = min(specular, 20.0);
    
    float3 diffuse = fragment_albedo * calculate_burley_diffuse(light_dir, view_vector, normal_vector, roughness);

    float normalDotLight = max(dot(normal_vector, light_dir), 0.0);

    float3 halfwayVector = normalize(view_vector + light_dir);
    float viewDotHalfway = max(dot(view_vector, halfwayVector), 0.0);

    float metallic = 0.0; // TODO extract this out

    // Energy conservation
    float3 fresnel = F_Schlick(viewDotHalfway, reflectivity);
    float3 kDiffuse = (1.0 - fresnel) * (1.0 - metallic);

    // Combine
    float3 colour = (kDiffuse * diffuse + specular) * light_colour * normalDotLight;

    // TODO resolve nans in light contribution calculation
    if (isnan(colour.r) || isnan(colour.g) || isnan(colour.b)) {
        colour.rgb = float3(1.0, 0.0, 0.0);
    }
    
    return colour;
}
