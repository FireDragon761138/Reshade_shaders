/*=============================================================================

    CRT_glass_effects.fx
    ----------------------------------------------------------------------------
    A small, optional companion to CRT.fx (AdvancedCRT). It fakes the two things
    that happen to light *inside the glass* of a real tube - and nothing else:

        * HALATION  -> the soft, warm/red glow that bleeds out of bright areas
                       as light scatters in the phosphor and back off the glass.
        * DIFFRACTION-> the faint chromatic spread light picks up passing through
                       the thick curved faceplate (red spreads wider than blue).

    This is NOT scanline bloom. There is no beam/scanline model here at all - it
    just takes whatever the picture already is and adds the glass on top. Run it
    *after* CRT.fx so it glows the finished tube image:

        NTSC_TV  ->  AdvancedCRT  ->  CRT_glass_effects

    How it works (cheap on purpose):
        1. Prefilter bright pixels into a half-res buffer (soft threshold).
        2. Separable Gaussian blur (one horizontal, one vertical pass).
        3. Combine: sample the glow per-channel with a tiny radial offset for
           diffraction, warm it for halation, add it back, then a Dry/Wet blend.

    Pair-friendly: leave it switched off and you lose nothing; switch it on for
    the "glass" layer over the tube.

=============================================================================*/

#include "ReShade.fxh"

// Glow runs at a fraction of screen res - cheaper, and naturally softer.
// A soft halo has no fine detail, so 1/4 res looks identical to full res
// while the blur touches 16x fewer pixels.
#ifndef GLASS_DOWNSCALE
    #define GLASS_DOWNSCALE 4
#endif

// Blur taps each side of center. Higher = smoother glow, a little slower.
#ifndef GLASS_SAMPLES
    #define GLASS_SAMPLES 6
#endif

// --------------------------------------------------------------------------
// Controls
// --------------------------------------------------------------------------
uniform float WetDry <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Dry / Wet";
    ui_tooltip = "Blend the whole glass effect against the clean image.\n"
                 "0 = off (dry), 1 = full effect (wet).";
    ui_category = "Mix";
> = 0.75;

uniform float Threshold <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Glow Threshold";
    ui_tooltip = "How bright a pixel must be before it starts to glow.\n"
                 "Lower = more of the picture blooms.";
    ui_category = "Glow";
> = 0.55;

uniform float Size <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Glow Size";
    ui_tooltip = "How far the glow spreads from bright areas.";
    ui_category = "Glow";
> = 2.5;

uniform float Intensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Glow Intensity";
    ui_tooltip = "Strength of the glow added on top of the picture.";
    ui_category = "Glow";
> = 0.9;

uniform float3 HalationTint <
    ui_type = "color";
    ui_label = "Halation Tint";
    ui_tooltip = "Color the glow is pushed toward. Real halation is warm/red\n"
                 "because long wavelengths scatter and penetrate the glass most.";
    ui_category = "Halation";
> = float3(1.0, 0.55, 0.40);

uniform float Warmth <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Halation Warmth";
    ui_tooltip = "How far the glow is tinted toward the halation color.\n"
                 "0 = keep the source color, 1 = fully tinted.";
    ui_category = "Halation";
> = 0.6;

uniform float Diffraction <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Diffraction";
    ui_tooltip = "Chromatic spread of the glow through the curved glass:\n"
                 "red is pushed outward, blue pulled in. Keep it subtle.";
    ui_category = "Diffraction";
> = 0.35;

// --------------------------------------------------------------------------
// Half-res ping-pong glow buffers
// --------------------------------------------------------------------------
texture tGlassA { Width = BUFFER_WIDTH / GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GLASS_DOWNSCALE; Format = RGBA16F; };
texture tGlassB { Width = BUFFER_WIDTH / GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GLASS_DOWNSCALE; Format = RGBA16F; };

sampler sGlassA { Texture = tGlassA; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };
sampler sGlassB { Texture = tGlassB; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

// --------------------------------------------------------------------------
// Passes
// --------------------------------------------------------------------------

// 1) Keep only the bright part of the picture (soft knee), preserving its color.
float3 PS_Prefilter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
    float  luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float  bright = max(luma - Threshold, 0.0) / (1.0 - Threshold + 1e-3);
    return c * bright;
}

// Separable Gaussian shared by both blur passes.
float3 GaussianBlur(sampler s, float2 uv, float2 dir)
{
    // Step is measured in *screen* pixels per tap, independent of the glow
    // buffer's downscale, so changing GLASS_DOWNSCALE (or the tap count) won't
    // rescale the look - "Size" keeps meaning the same spread. The 8/3 factor
    // keeps total reach matched to the old 8-tap / half-res version.
    float2 step = ReShade::PixelSize * (Size * (8.0 / 3.0)) * dir;

    const float sigma = GLASS_SAMPLES * 0.5;
    float3 sum = tex2D(s, uv).rgb;
    float  wsum = 1.0;

    [unroll]
    for (int i = 1; i <= GLASS_SAMPLES; i++)
    {
        float w = exp(-(i * i) / (2.0 * sigma * sigma));
        sum  += (tex2D(s, uv + step * i).rgb + tex2D(s, uv - step * i).rgb) * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

float3 PS_BlurH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGlassA, uv, float2(1.0, 0.0));
}

float3 PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGlassB, uv, float2(0.0, 1.0));
}

// 3) Add the glass on top of the scene.
float3 PS_Combine(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;

    // Diffraction: sample the glow per channel with a tiny radial scale around
    // screen center - red wider, green neutral, blue tighter.
    float2 dir = uv - 0.5;
    float  d = Diffraction * 0.015;
    float3 glow;
    glow.r = tex2D(sGlassA, 0.5 + dir * (1.0 + d)).r;
    glow.g = tex2D(sGlassA, uv).g;
    glow.b = tex2D(sGlassA, 0.5 + dir * (1.0 - d)).b;

    // Halation: push the glow toward the warm tint.
    glow = lerp(glow, glow * HalationTint, Warmth);

    // Add the glass layer; soft (screen-ish) so highlights don't hard-clip.
    float3 add = glow * Intensity;
    float3 lit = 1.0 - (1.0 - scene) * (1.0 - saturate(add));

    return lerp(scene, lit, WetDry);
}

technique CRT_Glass_Effects <
    ui_tooltip = "Halation + glass diffraction layer. Run AFTER CRT.fx.\n"
                 "Not scanline bloom - just the glow through the tube glass.";
>
{
    pass Prefilter { VertexShader = PostProcessVS; PixelShader = PS_Prefilter; RenderTarget = tGlassA; }
    pass BlurH     { VertexShader = PostProcessVS; PixelShader = PS_BlurH;     RenderTarget = tGlassB; }
    pass BlurV     { VertexShader = PostProcessVS; PixelShader = PS_BlurV;     RenderTarget = tGlassA; }
    pass Combine   { VertexShader = PostProcessVS; PixelShader = PS_Combine; }
}
