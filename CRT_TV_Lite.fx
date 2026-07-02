// CRT_TV_Lite.fx — a lightweight CRT-TV display shader for ReShade
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

// "Factory Tuning" - nobody at the plant was having a perfect day. Hands you one
// real set with its own little quirks baked in: a touch of misconvergence and
// white-balance drift, kept subtle so it reads as a "tuned" CRT, not a busted
// one. No geometry error on purpose (that's where it tips into "ruined").
// 0 = flawless calibration (default; compiled out). Any other integer is a random
// SEED, not a quality rank - each value is a different set off the line, so
// there's an endless supply of them and unit 2 is no worse than unit 1. Flip it
// on and the Price (what grandpa paid), Age (years left on) and Sharpness knobs
// show up to muck with it.
#ifndef FACTORY_TUNING
#define FACTORY_TUNING 0
#endif

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

// Cheap deterministic hash in [0,1] — the luck of the draw that decides how each
// "Factory Tuning" set rolled off the line (plus a few odd offsets), from a seed.
float Hash(float n) { return frac(sin(n * 12.9898) * 43758.5453); }

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

#if FACTORY_TUNING != 0
uniform float PRICE <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Price (Cheap - Nice)";
    ui_tooltip = "Factory Tuning hands you one actual set off the line, quirks and\n"
                 "all - nobody at the plant was having a perfect day.\n"
                 "\n"
                 "Price is what grandpa paid for it. Slide left for a bargain-bin\n"
                 "special that clearly left the factory on a Friday afternoon; slide\n"
                 "right for a fancy unit someone actually bothered to line up. The\n"
                 "posh ones hide their sins better (convergence most of all) - though\n"
                 "even the cheapos usually nailed skin tone.\n"
                 "Left = penny-pincher, right = money's-no-object.";
> = 0.0;

uniform float AGE <
    ui_type = "slider"; ui_min = 0.0; ui_max = 20.0; ui_step = 0.5;
    ui_label = "Age (years)";
    ui_tooltip = "How many years has this poor thing been left on? Box-fresh on the\n"
                 "left, two decades of Saturday-morning cartoons on the right.\n"
                 "\n"
                 "Old tubes get tired: the picture dims, loses its tan, and drifts a\n"
                 "touch green as the red gun clocks out first, while the corners go\n"
                 "soft and the colours wander out of line. Doesn't care how much you\n"
                 "paid - every set ends up here eventually.\n"
                 "0 = showroom shiny, 20 = grandma's attic.";
> = 0.0;
#endif

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

#if FACTORY_TUNING != 0
uniform float SHARPNESS <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Sharpness";
    ui_category = "Picture";
    ui_tooltip = "That sharpness knob every set had, cranked up in every showroom\n"
                 "to make the picture 'pop' - really just edge overshoot faking\n"
                 "detail. 0 = leave it alone. It's baked into the set's own circuitry,\n"
                 "so it only shows up with Factory Tuning.";
> = 0.0;
#endif

uniform int TEMPERATURE <
    ui_type = "combo";
    ui_label = "Color Temperature";
    ui_category = "Picture";
    ui_items = "Auto (matches mask)\0Neutral\0Warm\0Cool\0";
    ui_tooltip = "Colour tint of the picture.\n"
                 "Auto = a white point that fits the selected mask:\n"
                 "   Shadow Mask -> Warm (classic consumer-TV look);\n"
                 "   Aperture Grille & Slot Mask -> Neutral.\n"
                 "Neutral = untinted.\n"
                 "Warm = leans red.\n"
                 "Cool = leans blue (PC-monitor / high-colour-temp look).";
> = 0;

#if FACTORY_TUNING != 0
uniform float TINT <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Tint";
    ui_category = "Picture";
    ui_tooltip = "Flesh-tone tint, like the 'Tint'/'Flesh Tone' knob on an old TV -\n"
                 "but only acting on skin-range colours, not the whole picture.\n"
                 "0.5 = neutral (untouched). Slide toward 0 to lean flesh redder,\n"
                 "toward 1 to lean it more orange/yellow. The further from centre,\n"
                 "the stronger the bias.\n"
                 "Part of Factory Tuning (the set's own flesh-tone circuit).";
> = 0.5;
#endif

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
                 "Measured in pixels.";
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
    ui_type = "slider"; ui_min = 1.0; ui_max = 6.0; ui_step = 1.0;
    ui_label = "Mask Size";
    ui_category = "Phosphor Mask";
    ui_tooltip = "Size of the phosphor pattern, in screen pixels per stripe.\n"
                 "1 is finest; increase on high-resolution (1440p / 4K) displays\n"
                 "so the mask stays visible. Use whole numbers to avoid shimmer (moire).";
> = 1.0;

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

#if FACTORY_TUNING != 0
// Compact RGB<->HSV (standard formulations) for the skin-tone correction.
float3 RGBtoHSV(float3 c)
{
    float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
    float4 p = lerp(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
    float4 q = lerp(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
    float d = q.x - min(q.w, q.y);
    return float3(abs(q.z + (q.w - q.y) / (6.0 * d + 1e-10)), d / (q.x + 1e-10), q.x);
}
float3 HSVtoRGB(float3 c)
{
    float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    float3 p = abs(frac(c.xxx + K.xyz) * 6.0 - K.www);
    return c.z * lerp(K.xxx, saturate(p - K.xxx), c.y);
}

// TV-style "Flesh Tone"/"Tint" control. Real NTSC sets rotated the whole
// chroma phase with the Tint knob (set by eye on skin); "auto flesh" circuits
// instead nudged only colours near the flesh axis (+I, ~123 deg in YIQ). This
// combines the two: a skin-selective hue bias. 0.5 = neutral; the slider's
// distance from centre is the strength and its side is the direction, so one
// dial carries both. Part of Factory Tuning, so the per-unit flesh drift below
// always applies (even with the Tint dial left at neutral).
float3 SkinTone(float3 c)
{
    float bias = (TINT - 0.5) * 2.0;               // -1..+1: side = direction, |b| = strength

    const float FLESH = 28.0 / 360.0;              // flesh axis (orange-red) in [0,1]
    const float BAND  = 0.12;                      // width of the affected hue band
    const float MAX   = 18.0 / 360.0;              // hue shift at the slider extremes

    float3 hsv = RGBtoHSV(saturate(c));
    float d = abs(hsv.x - FLESH);
    d = min(d, 1.0 - d);                           // shortest distance on the hue circle
    float sel = smoothstep(BAND, 0.0, d) * saturate(hsv.y * 3.0);   // "how skin-like"

    // Bias skin hues toward red (bias < 0) or orange/yellow (bias > 0).
    hsv.x = frac(hsv.x + bias * MAX * sel);

#if FACTORY_TUNING != 0
    // Whoever set this one's tint at the factory had it a smidge off - 3-5 degrees
    // the wrong way, pick-your-direction. Splashing out on a nicer set (Price)
    // barely helps: getting hue about right was cheap, so even the budget boxes
    // managed it - hence the narrowest quality gap (~15%).
    float ft   = float(FACTORY_TUNING);
    float mag  = (3.0 + Hash(ft + 12.9) * 2.0) * lerp(1.0, 0.85, PRICE);  // 3..5 deg
    float sgn  = (Hash(ft + 11.7) < 0.5) ? -1.0 : 1.0;
    hsv.x = frac(hsv.x + (sgn * mag / 360.0) * sel);
#endif

    return HSVtoRGB(hsv);
}
#endif  // FACTORY_TUNING != 0

// TV picture controls, applied to the signal (gamma-encoded) the way a set's
// front-panel controls act on the incoming image.
float3 ApplyTV(float3 c)
{
    // Warm / cool / neutral tints (shared by the manual modes and Auto).
    static const float3 WARM = float3(1.06, 1.00, 0.92);
    static const float3 COOL = float3(0.94, 1.00, 1.08);
    static const float3 NEUT = float3(1.00, 1.00, 1.00);

    float3 temp;
    if (TEMPERATURE == 0)            // Auto: pick a white point to match the mask
        temp = (MASK_TYPE == 3) ? WARM      // shadow mask -> warm consumer-TV look
             :                    NEUT;     // aperture grille / slot / none -> neutral
    else                            // manual override
        temp = (TEMPERATURE == 2) ? WARM
             : (TEMPERATURE == 3) ? COOL
             :                      NEUT;   // TEMPERATURE == 1
    c *= temp;
#if FACTORY_TUNING != 0
    c  = SkinTone(c);                  // flesh-tone tint + per-unit factory drift

    // Per-unit factory trims that a real set makes on the gun drive (signal /
    // gamma space), NOT on emitted light - so they belong here, next to the
    // front-panel controls, not in the linear-light block. Doing them in linear
    // washed the mids and burned the highlights, worst on a cheap set. The
    // Hash() terms fold to compile-time constants, so this is a handful of mads.
    float ft = float(FACTORY_TUNING);
    float pv = lerp(1.0, 2.0 / 3.0, PRICE);        // Nice = ~1/3 less variance
    // "White" is never quite white - greys lean a little off-colour (+/- ~1.5%).
    c *= 1.0 + (float3(Hash(ft + 5.2), Hash(ft + 6.4), Hash(ft + 7.8)) - 0.5) * 0.03 * pv;
    // Brightness and contrast were never set the same on any two units (+/- ~5%
    // each); contrast pivots on signal mid-grey, like the knob it emulates.
    c *= 1.0 + (Hash(ft + 9.3) - 0.5) * 0.10 * pv;
    c  = (c - 0.5) * (1.0 + (Hash(ft + 10.1) - 0.5) * 0.10 * pv) + 0.5;
    // Colour cranked a bit hot from the factory (+5-8%) so it'd "pop" in the shop.
    float lumF = dot(c, LUMA);
    c = lerp(float3(lumF, lumF, lumF), c, 1.0 + (0.05 + Hash(ft + 11.3) * 0.03) * pv);
#endif
    c  = (c - 0.5) * CONTRAST + 0.5;   // contrast pivots on mid-gray
    c *= BRIGHTNESS;                   // then overall gain
    return max(c, 0.0);
}

// One graded source tap decoded to linear light. Used by the Q0 / SOFTNESS=0
// single-fetch path, the true-linear tiers (Q >= 2), and the Factory-Tuning
// sharpness circuit.
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
    float soft = SOFTNESS;
#if FACTORY_TUNING != 0
    // Focus was trimmed for the sweet spot in the middle and nobody cared about
    // the corners, so it's crisp in the centre and goes mushy at the edges:
    // ~0.5-1px extra spot at centre, ~1.5-3px out in the corners (480-ref),
    // scaled with resolution. A posh set (Price) holds focus tighter; an old one
    // (Age) lets it wander another ~50% by the time it's 20.
    float ft  = float(FACTORY_TUNING);
    float rad = length(pos - 0.5) * 1.414;
    float res = BUFFER_HEIGHT / 480.0;                    // 480p-ref px -> this display
    float priceVar = lerp(1.0, 2.0 / 3.0, PRICE);
    float ageSoft  = 1.0 + (AGE / 20.0) * 0.5;
    // ~1px extra spot at centre, ~2-3px at the corners (@1080p).
    soft += (0.44 + Hash(ft + 8.6) * 0.15 + rad * (0.5 + Hash(ft + 9.9) * 0.4))
          * res * priceVar * ageSoft;
#endif
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
// geometry so it scales with MASK_SIZE. Peaks stay at maskLight (the gentle
// fakelottes/lottes level); only the horizontal seam's dimming is compensated
// so slot/shadow masks hold the same average brightness as the aperture grille.
float3 PhosphorMask(float2 vpos)
{
    if (MASK_TYPE == 0) return float3(1.0, 1.0, 1.0);

    float triad    = 3.0 * MASK_SIZE;   // pixels per full RGB triad
    float xoff     = 0.0;               // horizontal stagger of alternate rows
    float seam     = 1.0;               // horizontal gap darkening (slot/shadow)
    float seamFrac = 0.0;               // fraction of the row that gap occupies

    if (MASK_TYPE == 2)              // slot mask: vertical RGB triads broken into tall
    {                                // brick-offset slots (consumer-TV slot mask)
        float cell = MASK_SIZE * 4.0;                             // tall slot cell (px)
        float col  = floor(vpos.x / triad);                       // which triad column
        float yoff = (frac(col * 0.5) < 0.5) ? 0.0 : cell * 0.5;  // interleave alt. columns
        seamFrac   = 0.30;                                        // slim gap between slots
        seam       = (frac((vpos.y + yoff) / cell) < seamFrac) ? maskDark : 1.0;
    }
    else if (MASK_TYPE == 3)         // shadow mask: RGB triads woven into fine dots -
    {                                // the compressed-TV phosphor look of fakelottes/lottes
        float cell = MASK_SIZE * 2.0;                             // short cell -> dots
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
// 'centerCol' reuses the already-sampled centre pixel (so factory convergence
// still applies there); the two neighbours cost one extra softened sample each.
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

float4 PS_CRTTV_Lite(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    // Untouched source, for the master Effect Strength blend.
    float3 orig = tex2D(ReShade::BackBuffer, texcoord).rgb;

    float2 pos = Warp(texcoord);

    // Softened source in linear light (TV grade + gamma decode handled inside).
    float3 lin = SampleSoftLinear(pos);

#if FACTORY_TUNING != 0
    // Everything this particular set got wrong on the assembly line, rolled fresh
    // from its seed and stuck with it for life.
    float ft = float(FACTORY_TUNING);
    float  res = BUFFER_HEIGHT / 480.0;                   // 480p-reference px -> this display
    float2 rc  = pos - 0.5;                               // -0.5..0.5 from centre
    float  rad = length(rc) * 1.414;                      // ~0 centre, ~1 corner

    // Paying more buys tighter tolerances; getting older loosens them again. The
    // money mostly shows in convergence (widest gap, ~40% off at Nice), barely at
    // all in tint, and a flat ~1/3 everywhere else - while Age comes for the
    // mechanical bits (convergence) no matter what you paid.
    float priceVar  = lerp(1.0, 2.0 / 3.0, PRICE);        // flat ~33% (WB, bright, sat, uniformity)
    float priceConv = lerp(1.0, 0.60,      PRICE);        // convergence: widest gap (~40%)
    float ageN      = AGE / 20.0;                         // 0 (new) .. 1 (20 years)
    float ageConv   = 1.0 + ageN * 0.7;                   // convergence drifts ~+70% by 20 yrs

    // The three electron guns never quite agree on where to point, so colour
    // fringes split apart - barely at the centre (~0.15-0.25% of screen height,
    // =1.5-2.5px @1080p) and worse toward the corners (~0.6-1%, =6-11px @1080p),
    // lopsided per axis because the yoke sat a touch crooked. Red and blue lean
    // opposite ways.
    float  ang  = Hash(ft + 1.3) * 6.2831853;             // centre-error direction
    float  cmag = (0.0015 + Hash(ft + 3.7) * 0.0010) * priceConv * ageConv;
    float2 gv   = float2(0.0045 + Hash(ft + 2.1) * 0.0025,// per-axis growth -> ~0.6-1% corner...
                         0.0045 + Hash(ft + 5.9) * 0.0025) * priceConv * ageConv; // anisotropy
    // fraction-of-height -> UV: * BUFFER_HEIGHT * (1/W, 1/H) = aspect-correct offset.
    float2 conv = (float2(cos(ang), sin(ang)) * cmag + rc * gv * 2.0)
                * BUFFER_HEIGHT * SourceSize.zw;
    // Single graded tap, not a full softening pass: the R/B fringe is a displaced
    // error, and re-softening it is invisible but costs a whole extra Sample per
    // channel (several scattered fetches + focus-drift recompute). This is the big
    // frametime win.
    lin.r = TapLinear(pos + conv).r;
    lin.b = TapLinear(pos - conv).b;

    // (White balance, brightness, contrast and saturation are signal-domain trims
    // and are applied in gamma space inside ApplyTV - doing them here in linear
    // light washed the mids and burned the highlights. What's left below is
    // genuinely light-domain: emission and phosphor effects.)

    // The corners never got quite as much juice as the middle - ~8-10% dimmer out
    // at the edges.
    lin *= 1.0 - rad * rad * (0.08 + Hash(ft + 13.1) * 0.02) * priceVar;

    // --- Age: the slow revenge of time, piled on top no matter what you paid. ---
    // Leave a tube on long enough and the whole picture just gives up and dims
    // (~10-20% down by a decade, up to ~22% at 20 yrs).
    lin *= 1.0 - ageN * 0.22;
    // The red gun always tires first while blue and green soldier on, so an old set
    // slowly loses its warmth and goes a bit sickly green. How fast depends on the
    // unit; green wilts a little too, blue hangs on.
    float redWear = ageN * (0.08 + Hash(ft + 14.2) * 0.08);   // ~8-16% red loss at 20 yrs
    lin.r *= 1.0 - redWear;
    lin.g *= 1.0 - redWear * 0.35;
    // As the guns weaken the colour washes out too (~20% by 20 yrs) - so that punchy
    // showroom set ends up both dim and faded, the exact opposite of how it shipped.
    float lumAge = dot(lin, LUMA);
    lin = lerp(float3(lumAge, lumAge, lumAge), lin, 1.0 - ageN * 0.20);   // up to ~20% desat

    // The old "sharpness" circuit - a cheap edge-boost that faked detail with a bit
    // of overshoot. It lived inside the set, so it only turns up with Factory Tuning.
    if (SHARPNESS > 0.0)
    {
        float2 dx = float2(SourceSize.z, 0.0) * res;      // ~1px @480, scales with resolution
        float3 hp = lin - 0.5 * (TapLinear(pos - dx) + TapLinear(pos + dx));
        lin += SHARPNESS * hp;
    }
#endif

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

technique CRT_TV_Lite
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_CRTTV_Lite;
    }
}
