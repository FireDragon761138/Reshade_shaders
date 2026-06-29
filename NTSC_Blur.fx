/*=============================================================================

    NTSC_Blur.fx
    ----------------------------------------------------------------------------
    A small, artistic stand-in for NTSC_TV.fx. Where NTSC_TV models the actual
    composite signal (dot crawl, cross-color rainbows, subcarrier), this just
    captures the *look* a composite signal leaves behind: a horizontal smear
    where color bleeds sideways much further than brightness.

    That asymmetry is the whole trick. On a real NTSC line the chroma carries
    far less bandwidth than the luma, so colors run and fringe horizontally
    while edges and brightness stay comparatively crisp. We reproduce it with
    one cheap horizontal pass:

        1. Convert each tap to YIQ (luma + two chroma axes).
        2. Blur Y narrowly (keeps detail), blur I/Q widely (the color bleed).
        3. Convert back to RGB and Dry/Wet blend.

    Horizontal only by design - vertical detail is left for the scanlines that
    come later. Put it BEFORE CRT.fx so the tube draws over the softened image:

        NTSC_Blur  ->  CRT.fx (AdvancedCRT)

    Use it instead of NTSC_TV when you want the soft composite feel without the
    full signal simulation (and a fraction of the cost).

=============================================================================*/

#include "ReShade.fxh"

// Taps each side of center. More = smoother bleed, slightly slower.
#ifndef NTSC_BLUR_SAMPLES
    #define NTSC_BLUR_SAMPLES 10
#endif

// --------------------------------------------------------------------------
// Controls
// --------------------------------------------------------------------------
uniform float Strength <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Dry / Wet";
    ui_tooltip = "Blend the whole effect against the clean image.\n"
                 "0 = off (dry), 1 = full effect (wet).";
    ui_category = "Mix";
> = 1.0;

uniform float ChromaBleed <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 16.0; ui_step = 0.1;
    ui_label = "Chroma Bleed";
    ui_tooltip = "How far color smears horizontally, in pixels.\n"
                 "This is the main NTSC 'look' - color running sideways.";
    ui_category = "NTSC Blur";
> = 6.0;

uniform float LumaBlur <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Luma Softness";
    ui_tooltip = "Horizontal softness of brightness/detail, in pixels.\n"
                 "Keep this well below Chroma Bleed - sharp luma, soft color\n"
                 "is what sells the composite look.";
    ui_category = "NTSC Blur";
> = 1.0;

// --------------------------------------------------------------------------
// YIQ <-> RGB (standard NTSC matrices)
// --------------------------------------------------------------------------
float3 RGBtoYIQ(float3 c)
{
    return float3(
        dot(c, float3(0.299,  0.587,  0.114)),
        dot(c, float3(0.596, -0.274, -0.322)),
        dot(c, float3(0.211, -0.523,  0.312)));
}

float3 YIQtoRGB(float3 c)
{
    return float3(
        dot(c, float3(1.0,  0.956,  0.619)),
        dot(c, float3(1.0, -0.272, -0.647)),
        dot(c, float3(1.0, -1.106,  1.703)));
}

// --------------------------------------------------------------------------
// Pass
// --------------------------------------------------------------------------
float3 PS_NTSCBlur(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;

    // Taps span the chroma reach; luma just rides the same taps with a much
    // tighter weight, so it stays sharp while chroma spreads.
    float pxPerTap = ChromaBleed / NTSC_BLUR_SAMPLES;          // screen px per step
    float sigmaL = max(LumaBlur, 1e-3);
    float sigmaC = max(ChromaBleed * 0.5, 1e-3);

    float3 c0 = RGBtoYIQ(orig);
    float  sumY  = c0.x;   float  wY = 1.0;
    float2 sumIQ = c0.yz;  float  wC = 1.0;

    [unroll]
    for (int i = 1; i <= NTSC_BLUR_SAMPLES; i++)
    {
        float d  = i * pxPerTap;                                // distance in px
        float gL = exp(-(d * d) / (2.0 * sigmaL * sigmaL));
        float gC = exp(-(d * d) / (2.0 * sigmaC * sigmaC));

        float2 off = float2(d * ReShade::PixelSize.x, 0.0);
        float3 l = RGBtoYIQ(tex2D(ReShade::BackBuffer, uv - off).rgb);
        float3 r = RGBtoYIQ(tex2D(ReShade::BackBuffer, uv + off).rgb);

        sumY  += (l.x  + r.x)  * gL;  wY += 2.0 * gL;
        sumIQ += (l.yz + r.yz) * gC;  wC += 2.0 * gC;
    }

    float3 yiq = float3(sumY / wY, sumIQ / wC);
    float3 result = YIQtoRGB(yiq);

    return lerp(orig, result, Strength);
}

technique NTSC_Blur <
    ui_tooltip = "Artistic composite-video smear: horizontal chroma bleed with\n"
                 "sharp luma. A light stand-in for NTSC_TV. Run BEFORE CRT.fx.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_NTSCBlur; }
}
