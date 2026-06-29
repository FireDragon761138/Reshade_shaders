#include "ReShade.fxh"

uniform float Exposure <
    ui_type = "slider";
    ui_min = -2.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Exposure (EV)";
    ui_tooltip = "Pushes values up before the curve. Since the backbuffer is already LDR, a small positive value gives AgX more highlight range to roll off.";
> = 0.2;

uniform float Saturation <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_label = "Saturation";
> = 1.0;

uniform float Contrast <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Contrast (Power)";
> = 1.0;

uniform float Strength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Blend Strength";
    ui_tooltip = "Mix between the original image and the AgX result.";
> = 1.0;

// sRGB -> AgX base (inset)
static const float3x3 agx_mat = float3x3(
    0.842479062253094,  0.0784335999999992, 0.0792237451477643,
    0.0423282422610123, 0.878468636469772,  0.0791661274605434,
    0.0423756549057051, 0.0784336,          0.879142973793104);

// AgX base -> sRGB (outset)
static const float3x3 agx_mat_inv = float3x3(
    1.19687900512017,   -0.0980208811401368, -0.0990297440797205,
   -0.0528968517574562,  1.15190312990417,   -0.0989611768448433,
   -0.0529716355144438, -0.0980434501171241,  1.15107367264116);

float3 agxDefaultContrastApprox(float3 x) {
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return  + 15.5   * x4 * x2
            - 40.14  * x4 * x
            + 31.96  * x4
            - 6.868  * x2 * x
            + 0.4298 * x2
            + 0.1191 * x
            - 0.00232;
}

float3 agx(float3 val) {
    const float min_ev = -12.47393;
    const float max_ev = 4.026069;
    val = mul(agx_mat, val);
    val = clamp(log2(max(val, 1e-10)), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    return agxDefaultContrastApprox(val);
}

float3 agxLook(float3 val) {
    const float3 lw = float3(0.2126, 0.7152, 0.0722);
    float luma = dot(val, lw);
    val = pow(max(val, 0.0), Contrast);          // contrast as power
    return luma + Saturation * (val - luma);     // ASC-CDL style saturation
}

float3 agxEotf(float3 val) {
    val = mul(agx_mat_inv, val);
    return pow(max(val, 0.0), 2.2);
}

float3 PS_AgX(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target {
    float3 color = tex2D(ReShade::BackBuffer, texcoord).rgb;
    float3 original = color;

    color = pow(max(color, 0.0), 2.2);   // sRGB -> linear
    color *= exp2(Exposure);             // exposure
    color = agx(color);                  // log + sigmoid
    color = agxLook(color);              // contrast / saturation
    color = agxEotf(color);              // outset matrix -> linear
    color = pow(max(color, 0.0), 1.0 / 2.2); // linear -> sRGB

    return lerp(original, color, Strength);
}

technique AgX <
    ui_tooltip = "AgX tonemapper - neutral, hue-preserving highlight roll-off.";
> {
    pass {
        VertexShader = PostProcessVS;
        PixelShader  = PS_AgX;
    }
}