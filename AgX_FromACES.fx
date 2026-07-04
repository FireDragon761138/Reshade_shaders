/*=============================================================================

    AgX_FromACES.fx  --  re-grade an ACES-tonemapped game to an AgX-style look

    ReShade sees the frame AFTER the game's tonemapper, so this cannot be a
    true tonemap swap. Instead it:

        backbuffer (sRGB)  ->  linear
                           ->  inverse ACES (recover pseudo scene-linear)
                           ->  AgX forward  (inset -> log2 -> sigmoid -> outset)
                           ->  sRGB encode

    The inverse ACES here is the analytic inverse of the Narkowicz "ACESFilm"
    approximation (the fit used by many UE/Unity titles). If your game uses the
    Hill/RRT fit the tone curve differs slightly; correct it with Pre-Exposure.

    Highlight recovery (phase 1): a fully white pixel is unrecoverable, but two
    pools of information survive and we exploit both:
      - PER-CHANNEL: most "clipped" pixels are bright saturated colors where only
        one or two channels railed. We reconstruct the clipped channel(s) from
        the surviving ones (hue-preserving), lifting them past the flat inverse
        clamp so AgX's path-to-white has real range to compress toward white.
      - SPATIAL (optional): for fully-clipped blobs we estimate how deep a pixel
        sits inside the blob (ring sampling) and raise a soft luminance dome, so
        big white patches get a gradient to desaturate along instead of a plateau.
      Both are plausible RECONSTRUCTION, not true recovery -- tune, don't trust.
      Interior of very large clipped regions still flattens; the compute
      mip-pyramid + bloom-guided version (phase 2) is what fixes that.

    8-bit expand/recompress bands slightly; Dither hides most of it. If the game
    can output HDR, prefer an HDR path -- the round-trip is far cleaner.

    AgX matrices/sigmoid: minimal AgX by Benjamin Wrensch, after Troy Sobotka.
    BSD-2-Clause.

=============================================================================*/

#include "ReShade.fxh"

// Spatial highlight-dome reconstruction for fully-clipped blobs (ring sampling,
// ~24 taps but only for clipped pixels). On by default; 0 = per-channel only.
#ifndef AGX_HIGHLIGHT_SPATIAL
#define AGX_HIGHLIGHT_SPATIAL 1
#endif

//-----------------------------------------------------------------------------
// UI
//-----------------------------------------------------------------------------

uniform float PreExposure <
    ui_type = "slider";
    ui_label = "Pre-Exposure (EV)";
    ui_tooltip = "Exposure applied to the recovered scene-linear image before AgX.\0Use this to match brightness if the game's ACES fit differs from Narkowicz.\0";
    ui_min = -3.0; ui_max = 3.0; ui_step = 0.01;
    ui_category = "Input";
> = 0.0;

uniform float HL_Strength <
    ui_type = "slider";
    ui_label = "Highlight Recovery";
    ui_tooltip = "Master blend for clipped-channel reconstruction. 0 = off.\0Lifts railed channels from the surviving ones so AgX path-to-white engages.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Highlight Recovery";
> = 0.75;

uniform float HL_ChannelPush <
    ui_type = "slider";
    ui_label = "Reconstruction Push";
    ui_tooltip = "How bright a clipped channel is assumed to have been.\0Higher = more aggressive path-to-white on clipped colors.\0";
    ui_min = 1.0; ui_max = 8.0; ui_step = 0.05;
    ui_category = "Highlight Recovery";
> = 3.0;

uniform float HL_ClipStart <
    ui_type = "slider";
    ui_label = "Clip Threshold";
    ui_tooltip = "sRGB level at/above which a channel counts as clipped.\0Lower catches near-clipped highlights too.\0";
    ui_min = 0.7; ui_max = 1.0; ui_step = 0.005;
    ui_category = "Highlight Recovery";
> = 0.85;

#if AGX_HIGHLIGHT_SPATIAL
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

uniform int LookPreset <
    ui_type = "combo";
    ui_label = "AgX Look";
    ui_items = "None (Base)\0Golden\0Punchy\0Custom\0";
    ui_category = "Look";
> = 2;

uniform float3 LookSlope <
    ui_type = "drag";
    ui_label = "Custom Slope";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Look";
> = float3(1.0, 1.0, 1.0);

uniform float3 LookPower <
    ui_type = "drag";
    ui_label = "Custom Power";
    ui_min = 0.1; ui_max = 3.0; ui_step = 0.01;
    ui_category = "Look";
> = float3(1.0, 1.0, 1.0);

uniform float LookOffset <
    ui_type = "slider";
    ui_label = "Custom Offset";
    ui_min = -0.2; ui_max = 0.2; ui_step = 0.001;
    ui_category = "Look";
> = 0.0;

uniform float LookSaturation <
    ui_type = "slider";
    ui_label = "Custom Saturation";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Look";
> = 1.0;

uniform float BlendAmount <
    ui_type = "slider";
    ui_label = "Blend With Original";
    ui_tooltip = "0 = original game image, 1 = full AgX regrade.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Output";
> = 1.0;

uniform float DitherAmount <
    ui_type = "slider";
    ui_label = "Dither";
    ui_tooltip = "Fights banding from the 8-bit expand/recompress round-trip.\0";
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
// Inverse ACES (Narkowicz analytic inverse)
//   Forward: y = (x(2.51x+0.03)) / (x(2.43x+0.59)+0.14), saturated.
//   Input c is display-linear (the game's ACES output, pre-gamma).
//-----------------------------------------------------------------------------

float3 InverseACES(float3 c)
{
    c = saturate(c);
    float3 disc = max(-1.0127 * c * c + 1.3702 * c + 0.0009, 0.0);
    return (-0.59 * c + 0.03 - sqrt(disc)) / (2.0 * (2.43 * c - 2.51));
}

//-----------------------------------------------------------------------------
// AgX forward
//-----------------------------------------------------------------------------

float3 AgxDefaultContrastApprox(float3 x)
{
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return  15.5    * x4 * x2
          - 40.14   * x4 * x
          + 31.96   * x4
          -  6.868  * x2 * x
          +  0.4298 * x2
          +  0.1191 * x
          -  0.00232;
}

float3 Agx(float3 val)
{
    static const float3x3 agx_inset = float3x3(
        0.842479062253094,  0.0784335999999992, 0.0792237451477643,
        0.0423282422610123, 0.878468636469772,  0.0791661274605434,
        0.0423756549057051, 0.0784336,           0.879142973793104);

    const float min_ev = -12.47393;
    const float max_ev =   4.026069;

    val = mul(agx_inset, val);
    val = clamp(log2(max(val, 1e-10)), min_ev, max_ev);
    val = (val - min_ev) / (max_ev - min_ev);
    val = AgxDefaultContrastApprox(val);
    return val;
}

float3 AgxEotf(float3 val)
{
    static const float3x3 agx_outset = float3x3(
         1.19687900512017,   -0.0980208811401368, -0.0990297440797205,
        -0.0528968517574562,  1.15190312990417,   -0.0989611768448433,
        -0.0529716355144438, -0.0980434501171241,  1.15107367264116);

    val = mul(agx_outset, val);
    val = pow(max(val, 0.0), 2.2);   // AgX EOTF -> linear light
    return val;
}

float3 AgxLook(float3 val)
{
    static const float3 lw = float3(0.2126, 0.7152, 0.0722);

    float3 slope  = float3(1.0, 1.0, 1.0);
    float3 power  = float3(1.0, 1.0, 1.0);
    float  offset = 0.0;
    float  sat    = 1.0;

    if (LookPreset == 1)         // Golden
    {
        slope = float3(1.0, 0.9, 0.5);
        power = float3(0.8, 0.8, 0.8);
        sat   = 0.8;
    }
    else if (LookPreset == 2)    // Punchy
    {
        power = float3(1.35, 1.35, 1.35);
        sat   = 1.4;
    }
    else if (LookPreset == 3)    // Custom
    {
        slope  = LookSlope;
        power  = LookPower;
        offset = LookOffset;
        sat    = LookSaturation;
    }

    // ASC CDL, applied in AgX encoded space
    val = pow(max(val * slope + offset, 0.0), power);
    float luma = dot(val, lw);
    return luma + sat * (val - luma);
}

//-----------------------------------------------------------------------------
// Highlight recovery (per-channel, hue-preserving)
//   Clipped channels were (at least) the brightest, so lift them above the
//   surviving channels and past the flat inverse clamp. `clip` is 0..1 per
//   channel (how railed it was); scene is post-inverse-ACES scene-linear.
//-----------------------------------------------------------------------------

float3 RecoverHighlights(float3 scene, float3 clip)
{
    float3 keep   = scene * (1.0 - clip);                 // surviving channels
    float  anchor = max(max(keep.r, keep.g), keep.b);     // hue/brightness ref
    float3 lifted = HL_ChannelPush * max(scene, anchor);  // extend clipped ones
    return lerp(scene, lifted, saturate(clip * HL_Strength));
}

//-----------------------------------------------------------------------------
// Dither (triangular, per-pixel)
//-----------------------------------------------------------------------------

float3 Dither(float2 uv)
{
    float3 seed = float3(12.9898, 78.233, 37.719);
    float3 n;
    n.r = frac(sin(dot(uv, seed.xy)) * 43758.5453);
    n.g = frac(sin(dot(uv, seed.yz)) * 43758.5453);
    n.b = frac(sin(dot(uv, seed.zx)) * 43758.5453);
    return (n - 0.5) / 255.0;   // ~1 LSB peak
}

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------

float3 PS_AgXFromACES(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, texcoord).rgb;

    // Recover pseudo scene-linear.
    float3 dlin  = SrgbToLinear(orig);
    float3 scene = max(InverseACES(dlin), 0.0);
    scene *= exp2(PreExposure);

    // --- highlight recovery ---
    // Per-channel clip amount from the (near-8-bit) sRGB backbuffer.
    float3 clip = smoothstep(HL_ClipStart, 1.0, orig);
    scene = RecoverHighlights(scene, clip);

#if AGX_HIGHLIGHT_SPATIAL
    // Spatial dome: for fully-clipped pixels, estimate how deep inside the blob
    // we sit (are our neighbours also clipped?) and raise a soft luminance dome.
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
                float3 ns  = tex2D(ReShade::BackBuffer, texcoord + off).rgb;
                float  nc  = min(min(smoothstep(HL_ClipStart, 1.0, ns.r),
                                     smoothstep(HL_ClipStart, 1.0, ns.g)),
                                     smoothstep(HL_ClipStart, 1.0, ns.b));
                float w = 1.0 / float(ri);                // weight near rings more
                depth += nc * w;
                wsum  += w;
            }
        }
        depth /= wsum;                                    // 0 at edge .. 1 deep in
        float dome = lerp(1.0, 1.0 + (HL_ChannelPush - 1.0) * 0.75, depth);
        scene = lerp(scene, scene * dome, allc * HL_SpatialAmount);
    }
#endif

    // AgX.
    float3 col = Agx(scene);
    col = AgxLook(col);
    col = AgxEotf(col);
    col = LinearToSrgb(col);

    // Blend + dither.
    col = lerp(orig, col, BlendAmount);
    col += Dither(texcoord) * DitherAmount;
    return saturate(col);
}

technique AgX_FromACES <
    ui_tooltip = "Re-grades an ACES-tonemapped image toward an AgX look.\nPlace LAST in your shader chain (after the game, before nothing).";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_AgXFromACES;
    }
}
