#include "ReShade.fxh"

uniform float Desaturation <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Desaturation";
    ui_tooltip = "Pulls saturation out globally. 0.3 to 0.5 is the grungy sweet spot.";
> = 0.4;

uniform float3 TintColor <
    ui_type = "color";
    ui_label = "Tint Color";
    ui_tooltip = "The cast. Default is the classic yellow-green piss filter.";
> = float3(0.93, 0.90, 0.68);

uniform float TintStrength <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Tint Strength";
> = 0.35;

uniform float Lift <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 0.2; ui_step = 0.005;
    ui_label = "Black Lift (Haze)";
    ui_tooltip = "Raises the blacks for that washed-out, hazy 2000s feel.";
> = 0.04;

uniform float Contrast <
    ui_type = "drag";
    ui_min = 0.7; ui_max = 1.3; ui_step = 0.01;
    ui_label = "Contrast";
> = 0.92;

uniform float Blend <
    ui_type = "drag";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Blend";
> = 1.0;

float3 PS_Grunge(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 col = orig;

    // desaturate toward luma
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    col = lerp(col, luma.xxx, Desaturation);

    // multiplicative tint cast, tied to luma so it sits in mids/highlights
    float3 tinted = col * TintColor;
    col = lerp(col, tinted, TintStrength);

    // lifted blacks for haze
    col = col * (1.0 - Lift) + Lift;

    // contrast pivot around mid-grey
    col = (col - 0.5) * Contrast + 0.5;

    return lerp(orig, saturate(col), Blend);
}

technique GrungeFilter
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Grunge;
    }
}