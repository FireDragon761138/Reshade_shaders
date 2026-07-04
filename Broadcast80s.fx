/*=============================================================================

    Broadcast80s.fx  --  simple 1980s broadcast-video color grade

    The lightweight, display-referred sibling of ACES_2_80s.fx. It does NOT undo
    ACES, recover highlights, or re-tonemap -- it just grades the image in front
    of it into 1980s broadcast colorimetry. Use this when you want the look
    without the ACES round-trip; use ACES_2_80s when you want highlight recovery.

    Fully self-contained. Does NOT do composite artifacts (NTSC_Blur) or the
    display transform (CRT shader).

    Pipeline:
        input -> linear (sRGB by default; #define B80S_LINEAR_IO 1 for linear)
              -> gamut remap -> white balance
              -> encode
              -> saturation -> highlight knee -> black setup -> studio levels
              -> output (same encoding as input)

    Chain order: Broadcast80s -> NTSC_Blur -> CRT. Round-trips in the input
    encoding so it respects the CRT-owns-the-display-transform rule.

    Gamut matrices: hand-derived Rec.709 -> target-on-709 (D65). BSD-2-Clause.

=============================================================================*/

#include "ReShade.fxh"

// Input/output encoding. Default = sRGB (gamma space). Define B80S_LINEAR_IO = 1
// if this runs on a linear buffer (input & output treated as linear, no sRGB).
#ifndef B80S_LINEAR_IO
#define B80S_LINEAR_IO 0
#endif

//-----------------------------------------------------------------------------
// UI
//-----------------------------------------------------------------------------

uniform int Gamut <
    ui_type = "combo";
    ui_label = "Gamut";
    ui_items = "Rec.709 (off)\0SMPTE-C (1980s NTSC)\0NTSC-1953 FCC (wide)\0";
    ui_tooltip = "SMPTE-C is the real 1980s broadcast-monitor gamut (subtle).\0NTSC-1953 is the wide FCC spec gamut: oversaturated, punchy.\0";
    ui_category = "Gamut";
> = 1;

uniform float GamutAmount <
    ui_type = "slider";
    ui_label = "Gamut Amount";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Gamut";
> = 1.0;

uniform float Saturation <
    ui_type = "slider";
    ui_label = "Saturation";
    ui_tooltip = "NTSC chroma was weak. <1 mutes it (Rec.601 luma).\0";
    ui_min = 0.0; ui_max = 1.5; ui_step = 0.01;
    ui_category = "Color";
> = 0.9;

uniform int WBPreset <
    ui_type = "combo";
    ui_label = "White Balance";
    ui_items = "D65 (Broadcast)\09300K (Cool / NTSC-J)\0Warm Tungsten\0";
    ui_category = "Color";
> = 0;

uniform float WBFine <
    ui_type = "slider";
    ui_label = "White Balance Fine";
    ui_tooltip = "- cool  /  + warm\0";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Color";
> = 0.0;

uniform float HighlightKnee <
    ui_type = "slider";
    ui_label = "Highlight Knee";
    ui_tooltip = "Soft highlight rolloff. Video rolls off; film clips.\0";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
    ui_category = "Levels";
> = 0.1;

uniform float BlackSetupIRE <
    ui_type = "slider";
    ui_label = "Black Setup (IRE)";
    ui_tooltip = "NTSC 7.5 IRE pedestal. 0 if your CRT shader owns black level.\0";
    ui_min = 0.0; ui_max = 10.0; ui_step = 0.1;
    ui_category = "Levels";
> = 0.0;

uniform bool StudioLevels <
    ui_label = "Studio Levels (16-235)";
    ui_tooltip = "Map full range into broadcast-legal 16-235.\0";
    ui_category = "Levels";
> = false;

uniform float BlendAmount <
    ui_type = "slider";
    ui_label = "Blend With Original";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Output";
> = 1.0;

uniform float DitherAmount <
    ui_type = "slider";
    ui_label = "Dither";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Output";
> = 1.0;

//-----------------------------------------------------------------------------
// Encoding
//-----------------------------------------------------------------------------

float3 SrgbToLinear(float3 c)
{
    float3 lo = c / 12.92;
    float3 hi = pow(max((c + 0.055) / 1.055, 0.0), 2.4);
    return lerp(hi, lo, step(c, 0.04045));
}

float3 LinearToSrgb(float3 c)
{
    c = max(c, 0.0);
    float3 lo = c * 12.92;
    float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;
    return lerp(hi, lo, step(c, 0.0031308));
}

float3 DecodeInput(float3 c)
{
#if B80S_LINEAR_IO
    return c;                       // linear passthrough
#else
    return SrgbToLinear(c);         // sRGB (default)
#endif
}

float3 EncodeOutput(float3 c)
{
#if B80S_LINEAR_IO
    return max(c, 0.0);
#else
    return LinearToSrgb(c);
#endif
}

//-----------------------------------------------------------------------------
// Gamut (combined Rec.709 -> target-on-709-display, both D65)
//-----------------------------------------------------------------------------

float3 ApplyGamut(float3 lin)
{
    static const float3x3 smptec = float3x3(
         0.939708,  0.050180,  0.010273,
         0.017772,  0.965770,  0.016432,
        -0.001622, -0.004369,  1.005751);

    static const float3x3 ntsc1953 = float3x3(
         1.461338, -0.384481, -0.076132,
        -0.026626,  0.965169,  0.061240,
        -0.026381, -0.041430,  1.067832);

    float3 conv = lin;
    if (Gamut == 1)      conv = mul(smptec,   lin);
    else if (Gamut == 2) conv = mul(ntsc1953, lin);
    else                 return lin;

    return lerp(lin, conv, GamutAmount);
}

//-----------------------------------------------------------------------------
// White balance / soft knee / dither
//-----------------------------------------------------------------------------

float3 WhiteBalanceGain()
{
    float3 g = float3(1.0, 1.0, 1.0);
    if (WBPreset == 1)      g = float3(0.90, 0.98, 1.14);   // 9300K cool
    else if (WBPreset == 2) g = float3(1.07, 1.00, 0.88);   // warm tungsten
    g.r *= 1.0 + 0.10 * WBFine;
    g.b *= 1.0 - 0.12 * WBFine;
    return g;
}

float SoftKnee1(float x, float knee)
{
    float t = 1.0 - knee;               // rolloff start
    float e = (x - t) / max(knee, 1e-5);
    float rolled = t + knee * (1.0 - exp(-e));
    return (x <= t) ? x : rolled;
}

float3 SoftKnee(float3 c, float knee)
{
    if (knee <= 0.0) return saturate(c);
    return float3(SoftKnee1(c.r, knee), SoftKnee1(c.g, knee), SoftKnee1(c.b, knee));
}

float3 Dither(float2 uv)
{
    float3 seed = float3(12.9898, 78.233, 37.719);
    float3 n;
    n.r = frac(sin(dot(uv, seed.xy)) * 43758.5453);
    n.g = frac(sin(dot(uv, seed.yz)) * 43758.5453);
    n.b = frac(sin(dot(uv, seed.zx)) * 43758.5453);
    return (n - 0.5) / 255.0;
}

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------

float3 PS_Broadcast80s(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // Grade in linear (gamut + white balance).
    float3 lin = DecodeInput(orig);
    lin = ApplyGamut(lin);
    lin *= WhiteBalanceGain();
    lin = max(lin, 0.0);

    // Back to the display signal for the video-level operations.
    float3 col = EncodeOutput(lin);

    // NTSC chroma weakness (Rec.601 luma).
    static const float3 luma601 = float3(0.299, 0.587, 0.114);
    float y = dot(col, luma601);
    col = y + Saturation * (col - y);
    col = max(col, 0.0);

    // Highlight knee, then video levels.
    col = SoftKnee(col, HighlightKnee);

    float setup = BlackSetupIRE / 100.0;
    col = col * (1.0 - setup) + setup;

    if (StudioLevels)
        col = col * (219.0 / 255.0) + (16.0 / 255.0);

    col = lerp(orig, col, BlendAmount);
    col += Dither(texcoord) * DitherAmount;
    return saturate(col);
}

technique Broadcast80s <
    ui_tooltip = "Simple 1980s broadcast color grade (no ACES undo).\nRun BEFORE NTSC_Blur and your CRT shader.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Broadcast80s;
    }
}
