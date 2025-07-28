struct PushConstants
{
    float2 src_texel_size;
    float mip_level;
    float filter_radius;
    float aspect_ratio;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

[[vk::binding(0, 0)]]
Texture2D src_buffer;
[[vk::binding(1, 0)]]
SamplerState src_sampler;

[shader("pixel")]
float4 ps_downsample(vs_out input) : SV_TARGET
{
    const float mip_level = push_constants.mip_level;

    float x = 1.0 / push_constants.src_texel_size.x;
    float y = 1.0 / push_constants.src_texel_size.y;

    // Take 13 samples around current texel:
    // a - b - c
    // - j - k -
    // d -[e]- f
    // - l - m -
    // g - h - i
    float3 a = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y + 2*y), mip_level).rgb;
    float3 b = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y + 2*y), mip_level).rgb;
    float3 c = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y + 2*y), mip_level).rgb;

    float3 d = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y), mip_level).rgb;
    float3 e = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y), mip_level).rgb;
    float3 f = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y), mip_level).rgb;

    float3 g = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - 2*x, input.uv.y - 2*y), mip_level).rgb;
    float3 h = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,       input.uv.y - 2*y), mip_level).rgb;
    float3 i = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + 2*x, input.uv.y - 2*y), mip_level).rgb;

    float3 j = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y + y), mip_level).rgb;
    float3 k = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y + y), mip_level).rgb;
    float3 l = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y - y), mip_level).rgb;
    float3 m = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y - y), mip_level).rgb;

    // Apply weighted distribution
    float3 downsample    = e*0.125;
    downsample          += (a+c+g+i)*0.03125;
    downsample          += (b+d+f+h)*0.0625;
    downsample          += (j+k+l+m)*0.125;

    return float4(downsample, 1.0);
}

[shader("pixel")]
float4 ps_upsample(vs_out input) : SV_TARGET
{
    const float mip_level = push_constants.mip_level;

    float x = push_constants.filter_radius;
    float y = push_constants.filter_radius * push_constants.aspect_ratio;

    // a - b - c
    // d -[e]- f
    // g - h - i
    float3 a = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y + y), mip_level).rgb;
    float3 b = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y + y), mip_level).rgb;
    float3 c = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y + y), mip_level).rgb;

    float3 d = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y), mip_level).rgb;
    float3 e = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y), mip_level).rgb;
    float3 f = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y), mip_level).rgb;

    float3 g = src_buffer.SampleLevel(src_sampler, float2(input.uv.x - x, input.uv.y - y), mip_level).rgb;
    float3 h = src_buffer.SampleLevel(src_sampler, float2(input.uv.x,     input.uv.y - y), mip_level).rgb;
    float3 i = src_buffer.SampleLevel(src_sampler, float2(input.uv.x + x, input.uv.y - y), mip_level).rgb;

    // Apply weighted distribution, by using a 3x3 tent filter
    float3 upsample = e*4.0;
    upsample += (b+d+f+h)*2.0;
    upsample += (a+c+g+i);
    upsample *= 1.0 / 16.0;

    return float4(upsample, 1.0);
}
