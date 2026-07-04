// CRT_Lite.fx — a lightweight CRT display shader for ReShade
//
// Features: Gaussian scanlines with brightness-driven beam bloom, procedural
// phosphor masks (aperture grille / slot / shadow), horizontal beam softening,
// barrel curvature, an optional vignette, and TV-style picture controls
// (brightness / contrast / colour temperature), plus a master effect blend.
//
// This is an original implementation written from the underlying display maths:
// Gaussian beam profiles, phosphor-triad geometry, and standard barrel
// distortion. It was inspired by the look of Timothy Lottes' CRT shader and
// hunterk's fakelottes, but shares no source code with either.
//
// Author: Firedragon761138
// Repository: https://github.com/FireDragon761138/Reshade_shaders
//
// Copyright (c) 2026 Firedragon761138
// SPDX-License-Identifier: BSD-2-Clause
// Licensed under the BSD 2-Clause License; see the repository README for the
// full license text.

#include "ReShade.fxh"

////////////////////////////////////////////////////////////////////
////////////////////////////  SETTINGS  ////////////////////////////
//#define ROTATE_SCANLINES  // for TATE (vertical) games: rotates scanlines
                            // and beam softening 90 degrees

// Quality / cost tier. Higher is more accurate but heavier; the compiler strips
// the paths you don't select, so each tier really is as cheap as it looks.
//   0 = Performance : single tap, no horizontal beam softening (SOFTNESS is
//                     ignored). One texture fetch - as light as it gets.
//   1 = Balanced    : 2-tap softening blended in nonlinear (gamma) light - the
//                     standard look, just two fetches. (default)
//   2 = High        : 3-tap softening in true linear light (per-tap decode) -
//                     cleaner across high-contrast edges.
//   3 = Reference   : 4-tap true linear light + colour-supersampled scanline AA.
//                     Heaviest.
// At any tier, if SOFTNESS is 0 (no beam blur) the sampler collapses to a single
// fetch automatically.
#ifndef CRT_QUALITY
#define CRT_QUALITY 1
#endif

// Interlaced mode: draw only one field (half the scan lines) each frame,
// alternating fields per frame, like a 480i tube. Best on a high-refresh
// display (120Hz+) so the two fields fuse instead of flickering. Brightness is
// preserved (each field is a full-brightness half-resolution image). 0 = off.
#ifndef INTERLACED
#define INTERLACED 0
#endif
////////////////////////////////////////////////////////////////////

static const float3 LUMA = float3(0.2126, 0.7152, 0.0722);

// In ReShade the processed image is the full backbuffer.
#define SourceSize float4(BUFFER_WIDTH, BUFFER_HEIGHT, BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)

#if INTERLACED
uniform int framecount < source = "framecount"; >;
#endif

// ======================  MASTER  ======================
uniform float EFFECT_STRENGTH <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Effect Strength";
    ui_tooltip = "Overall intensity of the whole CRT effect.\n"
                 "1.0 = full effect, 0.0 = your original image untouched.\n"
                 "Lower it to gently blend the CRT look over the clean image.";
> = 1.0;

// ====================  TV PICTURE  ====================
uniform float BRIGHTNESS <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Brightness";
    ui_category = "Picture";
    ui_tooltip = "Overall picture brightness, like a TV's brightness knob.\n"
                 "Raise it if the mask or scanlines make the image feel dim.\n"
                 "1.0 = unchanged.";
> = 1.0;

uniform float CONTRAST <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Contrast";
    ui_category = "Picture";
    ui_tooltip = "Contrast around mid-gray. Higher deepens blacks and brightens\n"
                 "whites for a punchier image; lower flattens it. 1.0 = unchanged.";
> = 1.0;

uniform int TEMPERATURE <
    ui_type = "combo";
    ui_label = "Color Temperature";
    ui_category = "Picture";
    ui_items = "Neutral\0Warm\0Cool\0";
    ui_tooltip = "Colour tint of the picture.\n"
                 "Neutral = untinted (default; a computer monitor's white point).\n"
                 "Warm = leans red (consumer-TV look).\n"
                 "Cool = leans blue (high-colour-temp look).";
> = 0;

// =====================  SCANLINES  ====================
uniform float SCANLINE_COUNT <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1080.0; ui_step = 1.0;
    ui_label = "Scanline Count";
    ui_category = "Scanlines";
    ui_tooltip = "Number of horizontal scan lines the tube draws.\n"
                 "0 = Auto: about a quarter of your screen height, giving\n"
                 "consistent ~4-pixel lines at any resolution (recommended).\n"
                 "Or set a specific count to match your content's vertical\n"
                 "resolution: 240 for retro / pixel-art, 480 for PS1 / VGA era.\n"
                 "Set it near your screen height to make scanlines fade away.";
> = 0.0;

uniform float SCANLINE_INTENSITY <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Scanline Intensity";
    ui_category = "Scanlines";
    ui_tooltip = "How pronounced the scanlines are - i.e. how dark the gaps\n"
                 "between lines get. 0 = no scanlines; higher = stronger lines.\n"
                 "Overall picture brightness stays constant as you change this.";
> = 0.45;

uniform float SCANLINE_SHARPNESS <
    ui_type = "slider"; ui_min = 2.0; ui_max = 16.0; ui_step = 0.5;
    ui_label = "Scanline Sharpness";
    ui_category = "Scanlines";
    ui_tooltip = "Shape of the scan-line beam. Higher = thin, sharp bright lines\n"
                 "with darker gaps; lower = soft, fat, gently blended lines.\n"
                 "Around 8 mimics a typical CRT.";
> = 8.0;

uniform float SCANLINE_BLOOM <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Scanline Bloom";
    ui_category = "Scanlines";
    ui_tooltip = "How much bright areas swell and bloom over the dark gaps, like\n"
                 "a real CRT beam. 0 = uniform lines everywhere; higher = highlights\n"
                 "glow and their scanlines fade out (so lines read most in mid-tones).";
> = 0.5;

uniform float SOFTNESS <
    ui_type = "slider"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Softness";
    ui_category = "Scanlines";
    ui_tooltip = "Horizontal blur along each scan line, emulating the beam's spot\n"
                 "size. 0 = sharp / pixel-crisp; higher = softer, more analog.\n"
                 "Measured in pixels at 1080p and auto-scaled to your resolution, so\n"
                 "the beam keeps the same apparent softness on a 1440p / 4K display.";
> = 1.0;

// =======================  MASK  =======================
uniform int MASK_TYPE <
    ui_type = "combo";
    ui_label = "Mask Type";
    ui_category = "Phosphor Mask";
    ui_items = "None\0Aperture Grille\0Slot Mask\0Shadow Mask\0";
    ui_tooltip = "The phosphor pattern of the simulated tube:\n"
                 "None - no mask.\n"
                 "Aperture Grille - vertical RGB stripes (Sony Trinitron / PVM).\n"
                 "Slot Mask - tall vertical RGB slots, offset like bricks (consumer TV).\n"
                 "Shadow Mask - RGB triads woven into fine dots (PC monitor / TV).";
> = 3;

uniform float MASK_SIZE <
    ui_type = "slider"; ui_min = 0.0; ui_max = 6.0; ui_step = 1.0;
    ui_label = "Mask Size";
    ui_category = "Phosphor Mask";
    ui_tooltip = "Size of the phosphor pattern, in screen pixels per stripe.\n"
                 "0 = Auto: picks a whole-pixel size that holds the same apparent\n"
                 "mask at any resolution (1 @ 1080p, 2 @ 4K) and stays moire-safe\n"
                 "(recommended, default). Or set 1-6 by hand; 1 is finest. Use whole\n"
                 "numbers to avoid shimmer (moire).";
> = 0.0;

uniform float MASK_STRENGTH <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Mask Strength";
    ui_category = "Phosphor Mask";
    ui_tooltip = "How strongly the phosphor mask is applied. 1 = full, 0 = off.\n"
                 "Lower it if the mask looks too heavy.";
> = 1.0;

uniform float maskLight <
    ui_type = "slider"; ui_min = 1.0; ui_max = 2.0; ui_step = 0.05;
    ui_label = "Mask Light";
    ui_category = "Phosphor Mask";
    ui_tooltip = "Brightness of the lit (glowing) phosphor stripes. Higher = punchier,\n"
                 "more saturated mask. 1.5 is a good default.";
> = 1.5;

uniform float maskDark <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05;
    ui_label = "Mask Dark";
    ui_category = "Phosphor Mask";
    ui_tooltip = "Brightness of the unlit gaps between phosphors. Lower = darker gaps\n"
                 "and a stronger, more contrasty mask; raise it if the mask feels heavy.";
> = 0.7;

// =====================  GEOMETRY  =====================
uniform float warpX <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.125; ui_step = 0.01;
    ui_label = "Curvature X";
    ui_category = "Geometry";
    ui_tooltip = "Horizontal screen curvature (barrel distortion) that bulges the\n"
                 "left and right edges like an old tube. 0 = flat. Small values\n"
                 "(around 0.02-0.05) look natural.";
> = 0.0;

uniform float warpY <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.125; ui_step = 0.01;
    ui_label = "Curvature Y";
    ui_category = "Geometry";
    ui_tooltip = "Vertical screen curvature, bulging the top and bottom edges.\n"
                 "0 = flat. Pair with Curvature X for a rounded CRT look.";
> = 0.0;

uniform float VIGNETTE <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Vignette";
    ui_category = "Geometry";
    ui_tooltip = "Darkening toward the corners, like a CRT's dimmer edges.\n"
                 "0 = off; higher = stronger corner falloff.";
> = 0.0;

// =======================  GAMMA  ======================
uniform float crt_gamma <
    ui_type = "slider"; ui_min = 1.0; ui_max = 4.0; ui_step = 0.05;
    ui_label = "CRT Gamma";
    ui_category = "Gamma";
    ui_tooltip = "Gamma the incoming image is decoded with before CRT processing.\n"
                 "With Monitor Gamma this sets the overall tone/contrast. Leave at\n"
                 "2.5 unless you're colour-matching a specific look.";
> = 2.5;

uniform float monitor_gamma <
    ui_type = "slider"; ui_min = 1.0; ui_max = 4.0; ui_step = 0.05;
    ui_label = "Monitor Gamma";
    ui_category = "Gamma";
    ui_tooltip = "Gamma of your actual display, used to re-encode the final image.\n"
                 "Set to your monitor's gamma (2.2 for most sRGB displays) so tones\n"
                 "look correct.";
> = 2.2;

// ---------------------------------------------------------------------------
// Barrel distortion. Pushes the edges out as a function of the squared
// distance along the perpendicular axis, then remaps to [0,1].
float2 Warp(float2 uv)
{
    float2 c = uv * 2.0 - 1.0;                       // center at origin, [-1,1]
    c *= float2(1.0 + c.y * c.y * warpX,
                1.0 + c.x * c.x * warpY);
    return c * 0.5 + 0.5;
}

// TV picture controls, applied to the signal (gamma-encoded) the way a set's
// front-panel controls act on the incoming image.
float3 ApplyTV(float3 c)
{
    // Warm / cool / neutral tints.
    static const float3 WARM = float3(1.06, 1.00, 0.92);
    static const float3 COOL = float3(0.94, 1.00, 1.08);
    static const float3 NEUT = float3(1.00, 1.00, 1.00);

    float3 temp = (TEMPERATURE == 1) ? WARM
                : (TEMPERATURE == 2) ? COOL
                :                      NEUT;   // TEMPERATURE == 0 = Neutral (default)
    c *= temp;
    c  = (c - 0.5) * CONTRAST + 0.5;   // contrast pivots on mid-gray
    c *= BRIGHTNESS;                   // then overall gain
    return max(c, 0.0);
}

// One graded source tap decoded to linear light. Used by the Q0 / SOFTNESS=0
// single-fetch path and by the true-linear tiers (Q >= 2).
float3 TapLinear(float2 p)
{
    return pow(abs(ApplyTV(tex2D(ReShade::BackBuffer, p).rgb)), crt_gamma);
}

// Softened source returned in LINEAR light. Blur along the scanline direction (a
// stand-in for the beam's horizontal spot size); weights sum to 1. Tap count and
// blend space scale with CRT_QUALITY:
//   Q0 : single tap, no horizontal softening (cheapest).
//   Q1 : 2 taps blended in nonlinear (gamma) light, graded + decoded once.
//   Q2 : 3 taps decoded to true linear light per tap, then blended.
//   Q3 : 4 taps in true linear light (a touch wider / smoother than Q2).
// Offsets are chosen so the blur width stays close as you change tiers. SOFTNESS
// = 0 collapses to a single fetch at every tier.
float3 SampleSoftLinear(float2 pos)
{
#if CRT_QUALITY == 0
    return TapLinear(pos);                               // 1-tap: no horizontal softening
#else
    // Softness is authored in 1080p pixels; scale it to the actual display so the
    // beam holds the same apparent spot size at 1440p / 4K (0 stays sharp).
    float soft = SOFTNESS * (BUFFER_HEIGHT / 1080.0);
    if (soft <= 0.0) return TapLinear(pos);              // no beam blur -> single fetch
#ifdef ROTATE_SCANLINES
    float2 dir = float2(0.0, SourceSize.w) * soft;       // beam runs vertically
#else
    float2 dir = float2(SourceSize.z, 0.0) * soft;       // beam runs horizontally
#endif
#if CRT_QUALITY == 1
    // 2-tap, nonlinear (gamma) blend: samples at +/-0.75*dir (blur width ~= the
    // 3-tap tier), graded + decoded once.
    float3 c  = tex2D(ReShade::BackBuffer, pos - dir * 0.75).rgb * 0.5;
    c        += tex2D(ReShade::BackBuffer, pos + dir * 0.75).rgb * 0.5;
    return pow(abs(ApplyTV(c)), crt_gamma);
#elif CRT_QUALITY == 2
    // 3-tap, true linear light: a centre-weighted Gaussian at 0 and +/-dir.
    float3 c  = TapLinear(pos      ) * 0.4545;
    c        += TapLinear(pos + dir) * 0.2727;
    c        += TapLinear(pos - dir) * 0.2727;
    return c;
#else
    // 4-tap, true linear light: symmetric Gaussian at +/-0.5*dir and +/-1.5*dir.
    float3 c  = TapLinear(pos - dir * 0.5) * 0.365;
    c        += TapLinear(pos + dir * 0.5) * 0.365;
    c        += TapLinear(pos - dir * 1.5) * 0.135;
    c        += TapLinear(pos + dir * 1.5) * 0.135;
    return c;
#endif
#endif
}

// Which of the three phosphor stripes does this horizontal phase light up?
// phase is in [0,3): [0,1) red, [1,2) green, [2,3) blue.
float3 StripeRGB(float phase)
{
    float3 m = float3(maskDark, maskDark, maskDark);
    if      (phase < 1.0) m.r = maskLight;
    else if (phase < 2.0) m.g = maskLight;
    else                  m.b = maskLight;
    return m;
}

// Procedural phosphor mask evaluated in output-pixel space. Built from triad
// geometry so it scales with the stripe size. Peaks stay at maskLight (the gentle
// fakelottes/lottes level); only the horizontal seam's dimming is compensated
// so slot/shadow masks hold the same average brightness as the aperture grille.
float3 PhosphorMask(float2 vpos)
{
    if (MASK_TYPE == 0) return float3(1.0, 1.0, 1.0);

    // Auto (MASK_SIZE < 1): pick a whole-pixel stripe width that keeps the mask a
    // constant apparent size across resolutions (1px @ 1080p, 2px @ 4K), rounded to
    // an integer so it stays aligned to the pixel grid and moire-free.
    float msize = (MASK_SIZE < 1.0) ? max(1.0, floor(BUFFER_HEIGHT / 1080.0 + 0.5))
                                    : MASK_SIZE;

    float triad    = 3.0 * msize;       // pixels per full RGB triad
    float xoff     = 0.0;               // horizontal stagger of alternate rows
    float seam     = 1.0;               // horizontal gap darkening (slot/shadow)
    float seamFrac = 0.0;               // fraction of the row that gap occupies

    if (MASK_TYPE == 2)              // slot mask: vertical RGB triads broken into tall
    {                                // brick-offset slots (consumer-TV slot mask)
        float cell = msize * 4.0;                                 // tall slot cell (px)
        float col  = floor(vpos.x / triad);                       // which triad column
        float yoff = (frac(col * 0.5) < 0.5) ? 0.0 : cell * 0.5;  // interleave alt. columns
        seamFrac   = 0.30;                                        // slim gap between slots
        seam       = (frac((vpos.y + yoff) / cell) < seamFrac) ? maskDark : 1.0;
    }
    else if (MASK_TYPE == 3)         // shadow mask: RGB triads woven into fine dots -
    {                                // the compressed-TV phosphor look of fakelottes/lottes
        float cell = msize * 2.0;                                 // short cell -> dots
        float col  = floor(vpos.x / triad);                       // which triad column
        float yoff = (frac(col * 0.5) < 0.5) ? 0.0 : cell * 0.5;  // interleave alt. columns
        seamFrac   = 0.5;                                         // half of each cell is gap
        seam       = (frac((vpos.y + yoff) / cell) < seamFrac) ? maskDark : 1.0;
    }

    float phase = frac((vpos.x + xoff) / triad) * 3.0;
    float3 m = StripeRGB(phase) * seam;

    // Compensate only the seam's duty cycle so brightness matches across mask
    // types; leaves the lit-phosphor peak at maskLight. Then blend by strength.
    float seamMean = (1.0 - seamFrac) + seamFrac * maskDark;
    m /= max(seamMean, 1e-3);
    return lerp(float3(1.0, 1.0, 1.0), m, MASK_STRENGTH);
}

// Gaussian scanline beam, applied in linear light. The beam widens with local
// luminance (SCANLINE_BLOOM), letting bright content bloom over the gaps.
float3 Beam(float2 coord, float3 lin)
{
    // Beam position measured in scan lines (not display pixels), so the
    // Gaussian is resolved across several output pixels and the scanlines are
    // visible and resolution-independent. 0 = auto: ~a quarter of the display
    // height (~4px lines) — the robust sweet spot for a single-sample beam.
    // (Finer, e.g. display/2, aliases to a flat/harsh pattern when point-sampled.)
#ifdef ROTATE_SCANLINES
    float lines = (SCANLINE_COUNT < 1.0) ? BUFFER_WIDTH  * 0.25 : SCANLINE_COUNT;
    float axis = coord.x, axisRcp = BUFFER_RCP_WIDTH;
#else
    float lines = (SCANLINE_COUNT < 1.0) ? BUFFER_HEIGHT * 0.25 : SCANLINE_COUNT;
    float axis = coord.y, axisRcp = BUFFER_RCP_HEIGHT;
#endif
#if INTERLACED
    lines *= 0.5;                           // one field = half the scan lines
#endif
    float p  = axis * lines;
#if INTERLACED
    p += float(framecount % 2) * 0.5;       // alternate field offset by half a line
#endif
    float fp = lines * axisRcp;             // scan-line units spanned by one output pixel

    float lum  = dot(lin, LUMA);
    float beam = SCANLINE_SHARPNESS * (1.0 - saturate(lum) * SCANLINE_BLOOM);

    // Period-average of the Gaussian (4-tap midpoint over one line pair).
    // Subtracting it makes the scanline energy-preserving: its mean is exactly
    // 1.0 for any intensity/sharpness/bloom, so enabling or strengthening
    // scanlines does not shift overall brightness or apparent gamma.
    float wAvg = 0.25 * (exp2(-beam * 0.0156) + exp2(-beam * 0.1406)
                       + exp2(-beam * 0.3906) + exp2(-beam * 0.7656));

    // 3x supersample of the beam across the pixel's footprint -> anti-aliased
    // scanlines that stay smooth under curvature and at any Scanline Count
    // (point-sampling forces coarse ~4px lines to avoid shimmer; this doesn't).
    float o  = fp * 0.3333;
    float d0 = abs(frac(p - o) - 0.5) * 2.0;
    float d1 = abs(frac(p    ) - 0.5) * 2.0;
    float d2 = abs(frac(p + o) - 0.5) * 2.0;
    float w  = (exp2(-beam * d0 * d0) + exp2(-beam * d1 * d1)
              + exp2(-beam * d2 * d2)) * 0.3333;

    float scan = 1.0 + SCANLINE_INTENSITY * (w - wAvg);
    return lin * scan;
}

#if CRT_QUALITY >= 3
// Colour-supersampled beam: re-samples the softened source at the vertical
// sub-positions and integrates the beam-weighted colours in linear light.
// 'centerCol' reuses the already-sampled centre pixel; the two neighbours cost
// one extra softened sample each.
float3 BeamColorAA(float2 coord, float3 centerCol)
{
#ifdef ROTATE_SCANLINES
    float lines  = (SCANLINE_COUNT < 1.0) ? BUFFER_WIDTH * 0.25 : SCANLINE_COUNT;
    float axis = coord.x, axisRcp = BUFFER_RCP_WIDTH;
    float2 subOff = float2(BUFFER_RCP_WIDTH, 0.0) * 0.3333;
#else
    float lines  = (SCANLINE_COUNT < 1.0) ? BUFFER_HEIGHT * 0.25 : SCANLINE_COUNT;
    float axis = coord.y, axisRcp = BUFFER_RCP_HEIGHT;
    float2 subOff = float2(0.0, BUFFER_RCP_HEIGHT) * 0.3333;
#endif
#if INTERLACED
    lines *= 0.5;
#endif
    float p  = axis * lines;
#if INTERLACED
    p += float(framecount % 2) * 0.5;
#endif
    float fp = lines * axisRcp;

    float lum  = dot(centerCol, LUMA);
    float beam = SCANLINE_SHARPNESS * (1.0 - saturate(lum) * SCANLINE_BLOOM);
    float wAvg = 0.25 * (exp2(-beam * 0.0156) + exp2(-beam * 0.1406)
                       + exp2(-beam * 0.3906) + exp2(-beam * 0.7656));
    float o  = fp * 0.3333;

    float dN = abs(frac(p - o) - 0.5) * 2.0;
    float d0 = abs(frac(p    ) - 0.5) * 2.0;
    float dP = abs(frac(p + o) - 0.5) * 2.0;
    float sN = 1.0 + SCANLINE_INTENSITY * (exp2(-beam * dN * dN) - wAvg);
    float s0 = 1.0 + SCANLINE_INTENSITY * (exp2(-beam * d0 * d0) - wAvg);
    float sP = 1.0 + SCANLINE_INTENSITY * (exp2(-beam * dP * dP) - wAvg);

    float3 cN = SampleSoftLinear(coord - subOff);
    float3 cP = SampleSoftLinear(coord + subOff);
    return (cN * sN + centerCol * s0 + cP * sP) * 0.3333;
}
#endif

// Corner falloff. Uses squared radial distance from center.
float Vignette(float2 uv)
{
    if (VIGNETTE <= 0.0) return 1.0;
    float2 d = (uv - 0.5) * 2.0;                     // -1..1 across the screen
    return saturate(1.0 - VIGNETTE * dot(d, d) * 0.5);
}

float4 PS_CRTLite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    // Untouched source, for the master Effect Strength blend.
    float3 orig = tex2D(ReShade::BackBuffer, texcoord).rgb;

    float2 pos = Warp(texcoord);

    // Softened source in linear light (TV grade + gamma decode handled inside).
    float3 lin = SampleSoftLinear(pos);

#if CRT_QUALITY >= 3
    lin  = BeamColorAA(pos, lin);   // colour-supersampled scanlines (before mask)
    lin *= PhosphorMask(vpos.xy);   // phosphor structure
#else
    lin *= PhosphorMask(vpos.xy);   // phosphor structure
    lin  = Beam(pos, lin);          // anti-aliased scanlines + beam bloom
#endif
    lin *= Vignette(pos);           // edge falloff

    float3 crt = pow(abs(lin), 1.0 / monitor_gamma);   // re-encode to display gamma

    // Anti-aliased tube edge: feather to black across ~1px at the (curved)
    // border, centred on the true edge so a flat (uncurved) screen isn't dimmed.
    float2 fw = max(fwidth(pos), 1e-6);
    float2 a  = smoothstep(-0.5 * fw, 0.5 * fw, pos);
    float2 b  = smoothstep(-0.5 * fw, 0.5 * fw, 1.0 - pos);
    crt *= a.x * a.y * b.x * b.y;

    return float4(lerp(orig, crt, EFFECT_STRENGTH), 1.0);
}

technique CRT_Lite
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CRTLite;
    }
}
