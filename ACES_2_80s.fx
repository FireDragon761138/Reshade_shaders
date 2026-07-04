/*=============================================================================

    ACES_2_80s.fx  --  re-grade an ACES-tonemapped game to 1980s broadcast video

    Sibling of AgX_FromACES: undo the game's ACES tone rendering, recover crushed
    highlights, then re-render through a video-style shoulder + 1980s broadcast
    colorimetry (SMPTE-C / NTSC gamut, Rec.601 chroma, video levels). Does NOT do
    composite artifacts (NTSC_Blur) or the display transform (CRT shader).

    Pipeline:
        input  -> linear (sRGB decode; this shader UNDOES ACES, so it expects a
                          display-referred SDR image -- i.e. an sRGB backbuffer)
               -> inverse ACES (recover pseudo scene-linear)
               -> highlight recovery (per-channel + optional spatial dome)
               -> gamut remap  -> white balance
               -> video tonemap (soft shoulder; recovered highlights roll off here)
               -> encode        -> saturation / black setup / studio levels
               -> output (same encoding as input)

    Highlight recovery mirrors AgX_FromACES: a fully white pixel is unrecoverable,
    but partially-clipped pixels reconstruct from surviving channels, and fully-
    clipped blobs get a soft luminance dome. Plausible reconstruction, not truth.

    Gamut matrices: hand-derived Rec.709->target-on-709 (D65). Inverse ACES:
    Narkowicz analytic inverse. BSD-2-Clause.

=============================================================================*/

#include "ReShade.fxh"

// Spatial highlight-dome reconstruction for fully-clipped blobs (~24 taps, only
// for clipped pixels). On by default; 0 = per-channel recovery only.
#ifndef A80S_HIGHLIGHT_SPATIAL
#define A80S_HIGHLIGHT_SPATIAL 1
#endif

//-----------------------------------------------------------------------------
// UI
//-----------------------------------------------------------------------------

uniform float PreExposure <
    ui_type = "slider";
    ui_label = "Pre-Exposure (EV)";
    ui_tooltip = "Exposure on the recovered scene-linear image before tone mapping.\0";
    ui_min = -3.0; ui_max = 3.0; ui_step = 0.01;
    ui_category = "Input";
> = 0.0;

uniform float HL_Strength <
    ui_type = "slider";
    ui_label = "Highlight Recovery";
    ui_tooltip = "Master blend for clipped-channel reconstruction. 0 = off.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Highlight Recovery";
> = 0.75;

uniform float HL_ChannelPush <
    ui_type = "slider";
    ui_label = "Reconstruction Push";
    ui_tooltip = "How bright a clipped channel is assumed to have been.\0";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.05;
    ui_category = "Highlight Recovery";
> = 3.0;

uniform float HL_ClipStart <
    ui_type = "slider";
    ui_label = "Clip Threshold (linear)";
    ui_tooltip = "Display-linear level at/above which a channel counts as clipped.\0";
    ui_min = 0.6; ui_max = 1.0; ui_step = 0.005;
    ui_category = "Highlight Recovery";
> = 0.9;

#if A80S_HIGHLIGHT_SPATIAL
uniform float HL_SpatialAmount <
    ui_type = "slider";
    ui_label = "Spatial Dome";
    ui_tooltip = "Reconstruct a luminance dome over fully-clipped blobs. 0 = off.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Highlight Recovery";
> = 0.5;

uniform float HL_SpatialRadius <
    ui_type = "slider";
    ui_label = "Dome Radius (px)";
    ui_min = 4.0; ui_max = 48.0; ui_step = 1.0;
    ui_category = "Highlight Recovery";
> = 16.0;
#endif

uniform float HighlightRolloff <
    ui_type = "slider";
    ui_label = "Highlight Rolloff (white pt)";
    ui_tooltip = "Scene-linear value that maps to display white. Higher = more\0highlight range compressed into the soft video shoulder.\0";
    ui_min = 1.0; ui_max = 20.0; ui_step = 0.1;
    ui_category = "Tone";
> = 8.0;

uniform int Gamut <
    ui_type = "combo";
    ui_label = "Gamut";
    ui_items = "Rec.709 (off)\0SMPTE-C (1980s NTSC)\0NTSC-1953 FCC (wide)\0";
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

uniform float BlackSetupIRE <
    ui_type = "slider";
    ui_label = "Black Setup (IRE)";
    ui_tooltip = "NTSC 7.5 IRE pedestal. 0 if your CRT shader owns black level.\0";
    ui_min = 0.0; ui_max = 10.0; ui_step = 0.1;
    ui_category = "Levels";
> = 0.0;

uniform bool StudioLevels <
    ui_label = "Studio Levels (16-235)";
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

//-----------------------------------------------------------------------------
// Inverse ACES (Narkowicz analytic inverse) -- input is display-linear
//-----------------------------------------------------------------------------

float3 InverseACES(float3 c)
{
    c = saturate(c);
    float3 disc = max(-1.0127 * c * c + 1.3702 * c + 0.0009, 0.0);
    return (-0.59 * c + 0.03 - sqrt(disc)) / (2.0 * (2.43 * c - 2.51));
}

//-----------------------------------------------------------------------------
// Highlight recovery (per-channel, hue-preserving)
//-----------------------------------------------------------------------------

float3 RecoverHighlights(float3 scene, float3 clip)
{
    float3 keep   = scene * (1.0 - clip);
    float  anchor = max(max(keep.r, keep.g), keep.b);
    float3 lifted = HL_ChannelPush * max(scene, anchor);
    return lerp(scene, lifted, saturate(clip * HL_Strength));
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
// White balance / video tonemap / dither
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

float3 VideoTonemap(float3 x, float w)
{
    // Extended Reinhard: 0->0, w->1, soft asymptotic shoulder (the "video"
    // rolloff). Recovered highlights get compressed toward white here.
    return (x * (1.0 + x / (w * w))) / (1.0 + x);
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

float3 PS_ACES2_80s(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // To display-linear (sRGB), then recover scene-linear.
    float3 dlin  = SrgbToLinear(orig);
    float3 scene = max(InverseACES(dlin), 0.0);
    scene *= exp2(PreExposure);

    // --- highlight recovery (clip detected in display-linear) ---
    float3 clip = smoothstep(HL_ClipStart, 1.0, dlin);
    scene = RecoverHighlights(scene, clip);

#if A80S_HIGHLIGHT_SPATIAL
    float allc = min(min(clip.r, clip.g), clip.b);
    if (HL_SpatialAmount > 0.0 && allc > 0.02)
    {
        float depth = 0.0;
        float wsum  = 0.0;
        [loop] for (int ri = 1; ri <= 3; ri++)
        {
            float rad = HL_SpatialRadius * (float(ri) / 3.0);
            [loop] for (int di = 0; di < 8; di++)
            {
                float  ang = 6.2831853 * (float(di) / 8.0);
                float2 off = float2(cos(ang), sin(ang)) * rad * ReShade::PixelSize;
                float3 ns  = SrgbToLinear(tex2D(ReShade::BackBuffer, texcoord + off).rgb);
                float  nc  = min(min(smoothstep(HL_ClipStart, 1.0, ns.r),
                                     smoothstep(HL_ClipStart, 1.0, ns.g)),
                                     smoothstep(HL_ClipStart, 1.0, ns.b));
                float w = 1.0 / float(ri);
                depth += nc * w;
                wsum  += w;
            }
        }
        depth /= wsum;
        float dome = lerp(1.0, 1.0 + (HL_ChannelPush - 1.0) * 0.75, depth);
        scene = lerp(scene, scene * dome, allc * HL_SpatialAmount);
    }
#endif

    // --- 1980s color science (scene-linear) ---
    scene = ApplyGamut(scene);
    scene *= WhiteBalanceGain();
    scene = max(scene, 0.0);

    // Video tonemap: soft shoulder brings recovered range back to [0,1].
    float3 disp = VideoTonemap(scene, HighlightRolloff);

    // --- encode, then video-signal grades ---
    float3 col = LinearToSrgb(disp);

    static const float3 luma601 = float3(0.299, 0.587, 0.114);
    float y = dot(col, luma601);
    col = y + Saturation * (col - y);
    col = max(col, 0.0);

    float setup = BlackSetupIRE / 100.0;
    col = col * (1.0 - setup) + setup;

    if (StudioLevels)
        col = col * (219.0 / 255.0) + (16.0 / 255.0);

    col = lerp(orig, col, BlendAmount);
    col += Dither(texcoord) * DitherAmount;
    return saturate(col);
}

technique ACES_2_80s <
    ui_tooltip = "ACES -> 1980s broadcast video, with crushed-highlight recovery.\nExpects an sRGB (display-referred) backbuffer. Run BEFORE NTSC_Blur / CRT.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_ACES2_80s;
    }
}
