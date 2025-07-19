
[[vk::binding(0, 0)]]
Texture2D hdr_buffer;

[[vk::binding(1, 0)]]
SamplerState hdr_sampler;

// [[vk::binding(2, 0)]]
// Texture2D bloom_buffer;

[shader("pixel")]
float4 ps_main(vs_out input) : SV_TARGET
{
    float3 hdr_colour = hdr_buffer.Sample(hdr_sampler, input.uv).rgb;
    // float3 bloom_colour = bloom_buffer.Sample(hdr_sampler, input.uv).rgb;
    // float3 mixed_colour = lerp(hdr_colour, bloom_colour, 0.04);
    float3 mixed_colour = hdr_colour;
    
    // ACES tonemapping
    float3 c = mixed_colour;
    float3 mapped_aces = (c*(2.51*c+0.03))/(c*(2.43*c+0.59)+0.14);
    float4 toned_colour = float4(saturate(mapped_aces), 1.0);

#ifdef BLACK_AND_WHITE
    // gamma correct and convert to grayscale
    toned_colour = pow(toned_colour, float4(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2, 1.0));
    float value = toned_colour.r * 0.299 + toned_colour.g * 0.587 + toned_colour.b * 0.114;
    value = saturate(value);
    toned_colour = float4(value, value, value, 1.0);

    // return to linear space
    toned_colour = pow(toned_colour, float4(2.2, 2.2, 2.2, 1.0));
#endif

    return toned_colour;
}
