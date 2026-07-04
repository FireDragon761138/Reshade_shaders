/*=============================================================================

    Broadcast80s.fx  --  re-grade a modern (ACES/Rec.709) game toward the
                         colorimetry & tonal signature of 1980s broadcast video

    This is the COLOR SCIENCE layer, not the signal layer. It deliberately does
    NOT do composite artifacts (dot crawl, chroma bleed -> use NTSC_Blur) or the
    final display transform (gamma/scanlines -> your CRT shader). It stays a
    self-contained sRGB -> sRGB grade and should run BEFORE NTSC_Blur / CRT.

    What it models:
      - Gamut  : Rec.709 -> SMPTE-C (1980s NTSC studio monitor) or the wide
                 NTSC-1953 FCC primaries. Matrices are the combined
                 Rec.709->target->Rec.709-display transform, both at D65, so
                 white stays neutral and only the primaries shift.
      - Chroma : NTSC's characteristic weak/uneven saturation (Rec.601 luma).
      - Balance: broadcast D65 vs the cool 9300K consumer/NTSC-J set, or warm
                 tungsten telecine.
      - Levels : 7.5 IRE black setup (the NTSC pedestal), optional 16-235 studio
                 range, and a soft highlight knee (video rolls off, film clips).

    NOTE on your chain: your CRT shader owns black level / gamma. So Black Setup,
    Studio Levels, and the knee default to conservative/off values -- turn them
    up only if you want this shader to carry the video-levels look itself.

    BSD-2-Clause.

=============================================================================*/

#include "ReShade.fxh"

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
    ui_tooltip = "NTSC chroma was famously weak/unstable. <1 mutes it.\0";
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

uniform float BlackSetupIRE <
    ui_type = "slider";
    ui_label = "Black Setup (IRE)";
    ui_tooltip = "NTSC 7.5 IRE pedestal (milky blacks). 0 if your CRT shader owns black level.\0";
    ui_min = 0.0; ui_max = 10.0; ui_step = 0.1;
    ui_category = "Levels";
> = 0.0;

uniform bool StudioLevels <
    ui_label = "Studio Levels (16-235)";
    ui_tooltip = "Map full range into broadcast-legal 16-235.\0";
    ui_category = "Levels";
> = false;

uniform float HighlightKnee <
    ui_type = "slider";
    ui_label = "Highlight Knee";
    ui_tooltip = "Soft highlight rolloff. Video rolls off; film clips.\0";
    ui_min = 0.0; ui_max = 0.5; ui_step = 0.01;
    ui_category = "Levels";
> = 0.1;

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
// Color space helpers (accurate sRGB, componentwise)
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

//-----------------------------------------------------------------------------
// Gamut (combined Rec.709 -> target-on-709-display, both D65, hand-derived)
//-----------------------------------------------------------------------------

float3 ApplyGamut(float3 lin)
{
    // SMPTE-C (SMPTE 170M) primaries, D65.
    static const float3x3 smptec = float3x3(
         0.939708,  0.050180,  0.010273,
         0.017772,  0.965770,  0.016432,
        -0.001622, -0.004369,  1.005751);

    // NTSC-1953 FCC primaries, adapted to D65 (wide gamut -> punchy).
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
// White balance
//-----------------------------------------------------------------------------

float3 WhiteBalanceGain()
{
    float3 g = float3(1.0, 1.0, 1.0);
    if (WBPreset == 1)      g = float3(0.90, 0.98, 1.14);   // 9300K cool
    else if (WBPreset == 2) g = float3(1.07, 1.00, 0.88);   // warm tungsten

    // Fine trim: + warm, - cool.
    g.r *= 1.0 + 0.10 * WBFine;
    g.b *= 1.0 - 0.12 * WBFine;
    return g;
}

//-----------------------------------------------------------------------------
// Soft highlight knee (per channel, asymptotes to 1.0, never clips hard)
//-----------------------------------------------------------------------------

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

//-----------------------------------------------------------------------------
// Dither
//-----------------------------------------------------------------------------

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

    // --- linear-light operations ---
    float3 lin = SrgbToLinear(orig);
    lin = ApplyGamut(lin);
    lin *= WhiteBalanceGain();
    lin = max(lin, 0.0);

    // --- back to gamma / video-signal operations ---
    float3 col = LinearToSrgb(lin);

    // NTSC chroma weakness (Rec.601 luma).
    static const float3 luma601 = float3(0.299, 0.587, 0.114);
    float y = dot(col, luma601);
    col = y + Saturation * (col - y);
    col = max(col, 0.0);

    // Highlight knee, then video levels.
    col = SoftKnee(col, HighlightKnee);

    float setup = BlackSetupIRE / 100.0;        // 7.5 IRE -> 0.075
    col = col * (1.0 - setup) + setup;

    if (StudioLevels)
        col = col * (219.0 / 255.0) + (16.0 / 255.0);

    // Blend + dither.
    col = lerp(orig, col, BlendAmount);
    col += Dither(texcoord) * DitherAmount;
    return saturate(col);
}

technique Broadcast_1980s <
    ui_tooltip = "1980s broadcast colorimetry (SMPTE-C gamut, NTSC chroma, video levels).\nRun BEFORE NTSC_Blur and your CRT shader.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Broadcast80s;
    }
}
