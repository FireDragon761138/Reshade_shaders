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
// It also reads the Mask Type as the set's pedigree: Aperture Grille = the premium
// Japanese Trinitron (tight, holds up for years), while Slot Mask and Shadow Mask
// are the two mainstream in-line-gun tubes that filled ordinary living rooms -
// peers, with the Price knob (not the mask) deciding build quality. Each tube type
// is still wrong in a way that fits how it was built and how it ages.
// The picture also boots into a restrained showroom default (cool ~9300K, mildly
// punchy, sharpness left cranked) - what these sets actually looked like new.
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
> = 0.5;   // default: an average, middle-of-the-catalogue set

uniform float AGE <
    ui_type = "slider"; ui_min = 0.0; ui_max = 20.0; ui_step = 0.5;
    ui_label = "Age (years)";
    ui_tooltip = "How many years has this poor thing been left on? Box-fresh on the\n"
                 "left, two decades of Saturday-morning cartoons on the right.\n"
                 "\n"
                 "Old tubes get tired: the picture dims, the whites go yellow and the\n"
                 "colour washes out as the blue gun fades first, while the corners go\n"
                 "soft and the guns wander out of line. Doesn't care how much you\n"
                 "paid - every set ends up here eventually.\n"
                 "0 = showroom shiny, 20 = grandma's attic.";
> = 4.0;   // default: a few years in - lived-in, not box-fresh, not clapped-out
#endif

// ====================  TV PICTURE  ====================
uniform float BRIGHTNESS <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Brightness";
    ui_category = "Picture";
    ui_tooltip = "Overall picture brightness, like a TV's brightness knob.\n"
                 "Raise it if the mask or scanlines make the image feel dim.\n"
#if FACTORY_TUNING != 0
                 "Factory Tuning starts it a touch hot - the showroom default,\n"
                 "nudged back down by an owner who sort of cared.\n"
#endif
                 "1.0 = unchanged.";
> =
#if FACTORY_TUNING != 0
    1.08;   // punchy factory default, nudged back from the showroom extreme
#else
    1.0;
#endif

uniform float CONTRAST <
    ui_type = "slider"; ui_min = 0.5; ui_max = 1.5; ui_step = 0.01;
    ui_label = "Contrast";
    ui_category = "Picture";
    ui_tooltip = "Contrast around mid-gray. Higher deepens blacks and brightens\n"
#if FACTORY_TUNING != 0
                 "whites for a punchier image; lower flattens it.\n"
                 "Factory Tuning starts it mildly punchy - the showroom look, backed\n"
                 "off from the crushed extreme. 1.0 = unchanged.";
#else
                 "whites for a punchier image; lower flattens it. 1.0 = unchanged.";
#endif
> =
#if FACTORY_TUNING != 0
    1.10;   // mildly punchy factory default (showroom, backed off the extreme)
#else
    1.0;
#endif

#if FACTORY_TUNING != 0
uniform float SHARPNESS <
    ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Sharpness";
    ui_category = "Picture";
    ui_tooltip = "That sharpness knob every set had, cranked up in every showroom\n"
                 "to make the picture 'pop' - really just edge overshoot faking\n"
                 "detail. Starts mildly cranked, like the factory left it and the\n"
                 "owner never thought to turn it down; drag to 0 to leave it alone.\n"
                 "It's baked into the set's own circuitry, so it only shows up with\n"
                 "Factory Tuning.";
> = 0.2;
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
                 "Warm = leans red (closer to broadcast spec - the enthusiast's pick).\n"
                 "Cool = leans blue (PC-monitor / high-colour-temp look)."
#if FACTORY_TUNING != 0
                 "\n\n"
                 "Factory Tuning defaults this to Cool: the bluish (~9300K) showroom\n"
                 "white these sets actually shipped at and most owners never touched.\n"
                 "Crank Age and the blue fades on its own, warming it back toward\n"
                 "neutral - no need to touch this."
#endif
                 ;
> =
#if FACTORY_TUNING != 0
    3;      // Cool: the bluish ~9300K showroom default these sets shipped at
#else
    0;
#endif

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
                 "Slot Mask - tall vertical RGB slots, offset like bricks. The in-line-\n"
                 "   gun tube that filled most US and UK living rooms (default).\n"
                 "Shadow Mask - RGB triads woven into fine dots (TV and PC monitor).";
> = 2;

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

#if FACTORY_TUNING != 0
// Per-mask provenance. Only one tube type really stands apart: the aperture
// grille (Sony Trinitron / Mitsubishi Diamondtron) was the premium Japanese set -
// tighter QC, finer pitch, and beam-current feedback that holds calibration for
// years. The other two, slot mask and dot-trio shadow mask, were the mainstream
// in-line-gun tubes that filled ordinary US and European living rooms; they're
// peers, NOT a quality ladder. Which mask a set used didn't decide how well it was
// built - its price did, and the Price knob already covers that. Dot-trio shadow
// mask spanned a slightly wider range (cheap sets through fine-pitch monitors), so
// it carries a touch more scatter than slot mask, but they're close.
// Returned packed: x = convergence tightness, y = focus tightness, z = general
// variance (white balance / brightness / contrast / saturation / uniformity),
// w = how gracefully it ages (mechanical drift, dimming, colour hold). Lower is
// tighter/better; these scale the per-unit error so each tube is wrong in a way
// that fits how it was built. Price and Age still ride on top.
float4 ProvFactors()
{
    if (MASK_TYPE == 1) return float4(0.50, 0.60, 0.70, 0.65);   // aperture grille (premium JP)
    if (MASK_TYPE == 2) return float4(0.88, 0.90, 0.90, 0.90);   // slot mask (mainstream default)
    return float4(0.94, 0.90, 0.90, 0.94);                       // shadow mask / none (mainstream)
}

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
    // Every NTSC set shipped with a built-in "red push" - the chroma decoder was
    // deliberately biased to warm up skin under the bluish (~9300K) white these
    // sets ran at. So flesh leans a consistent couple of degrees redder, not a
    // random wobble; only how much varies unit to unit (~1.5-3 deg). Getting hue
    // about right was cheap, so even the budget boxes managed it and a nicer set
    // (Price) barely pulls it back - hence the narrowest quality gap.
    float ft   = float(FACTORY_TUNING);
    float mag  = (1.5 + Hash(ft + 12.9) * 1.5) * lerp(1.0, 0.8, PRICE);  // 1.5..3 deg, redward
    hsv.x = frac(hsv.x - (mag / 360.0) * sel);
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
    // Nice set = ~1/3 less variance; a premium tube type (aperture grille) tighter
    // still, a budget shadow mask at the full baseline.
    float pv = lerp(1.0, 2.0 / 3.0, PRICE) * ProvFactors().z;
    // "White" is never quite white - greys lean a little off-colour (+/- ~1.5%).
    c *= 1.0 + (float3(Hash(ft + 5.2), Hash(ft + 6.4), Hash(ft + 7.8)) - 0.5) * 0.03 * pv;
    // Brightness and contrast were never set the same on any two units (+/- ~5%
    // each); contrast pivots on signal mid-grey, like the knob it emulates.
    c *= 1.0 + (Hash(ft + 9.3) - 0.5) * 0.10 * pv;
    c  = (c - 0.5) * (1.0 + (Hash(ft + 10.1) - 0.5) * 0.10 * pv) + 0.5;
    // Colour nudged a touch hot from the factory (+3-6%) so it'd "pop" in the shop.
    float lumF = dot(c, LUMA);
    c = lerp(float3(lumF, lumF, lumF), c, 1.0 + (0.03 + Hash(ft + 11.3) * 0.03) * pv);
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
    // Softness is authored in 1080p pixels; scale it to the actual display so the
    // beam holds the same apparent spot size at 1440p / 4K (0 stays sharp).
    float soft = SOFTNESS * (BUFFER_HEIGHT / 1080.0);
#if FACTORY_TUNING != 0
    // Focus was trimmed for the sweet spot in the middle, so the centre stays
    // near-crisp and the spot only swells out toward the corners where the beam
    // lands obliquely - an inherent tube trait, tidy in the middle, soft at the
    // edges. A posh set (Price) holds focus tighter, and so does a better tube type
    // (aperture grille sharpest, shadow mask softest); an old one (Age) lets it
    // wander another ~50% by the time it's 20 - though a premium tube holds on.
    float ft  = float(FACTORY_TUNING);
    float4 prov = ProvFactors();
    float rad = length(pos - 0.5) * 1.414;
    float res = BUFFER_HEIGHT / 480.0;                    // 480p-ref px -> this display
    float priceVar = lerp(1.0, 2.0 / 3.0, PRICE) * prov.y;
    float ageSoft  = 1.0 + (AGE / 20.0) * prov.w * 0.5;
    // near-crisp centre (~0.3-0.5px), ~1.5-2px softer at the corners (@1080p).
    soft += (0.12 + Hash(ft + 8.6) * 0.10 + rad * rad * (0.6 + Hash(ft + 9.9) * 0.5))
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

    // Paying more buys tighter tolerances; getting older loosens them again; and
    // the tube's pedigree (ProvFactors, by Mask Type) sets the baseline both ride
    // on. The money mostly shows in convergence (widest gap, ~40% off at Nice),
    // barely at all in tint, and a flat ~1/3 everywhere else - while Age comes for
    // the mechanical bits (convergence) no matter what you paid.
    float4 prov     = ProvFactors();                      // per-tube-type quality & aging grace
    float priceVar  = lerp(1.0, 2.0 / 3.0, PRICE) * prov.z;   // WB / bright / sat / uniformity
    float priceConv = lerp(1.0, 0.60,      PRICE) * prov.x;   // convergence: widest gap (~40%)
    float ageN      = AGE / 20.0;                         // 0 (new) .. 1 (20 years) - phosphor clock
    // Mechanical/emission ageing (convergence drift, dimming, white-balance hold)
    // is what premium sets shrug off - beam-current feedback and a stiffer yoke -
    // so it runs on a slowed clock; the phosphor's own blue-first fade (ageN) is
    // chemistry every tube shares.
    float ageMech   = ageN * prov.w;
    float ageConv   = 1.0 + ageMech * 0.7;                // convergence drift over life

    // The three electron guns never quite agree on where to point, so colour
    // fringes split apart - a hair at the centre (~0.04-0.07% of screen height,
    // =0.4-0.8px @1080p) and wider toward the corners (~0.15-0.25%, =1.5-2.5px
    // @1080p), lopsided per axis because the yoke sat a touch crooked. That's an
    // inherent three-gun tube trait, not neglect - even a nicely lined-up consumer
    // set does this much. Red and blue lean opposite ways.
    float  ang  = Hash(ft + 1.3) * 6.2831853;             // centre-error direction
    float  cmag = (0.0004 + Hash(ft + 3.7) * 0.0003) * priceConv * ageConv;
    float2 gv   = float2(0.0011 + Hash(ft + 2.1) * 0.0007,// per-axis growth -> ~1.5-2.5px corner...
                         0.0011 + Hash(ft + 5.9) * 0.0007) * priceConv * ageConv; // anisotropy
    // fraction-of-height -> UV: * BUFFER_HEIGHT * (1/W, 1/H) = aspect-correct offset.
    float2 conv = (float2(cos(ang), sin(ang)) * cmag + rc * gv * 2.0)
                * BUFFER_HEIGHT * SourceSize.zw;
    // Aperture grille runs continuous vertical stripes, so a vertical convergence
    // error just slides along the stripe and never fringes - only the horizontal
    // R/B split shows. Collapse the invisible axis on that tube type (on top of its
    // already-tight convergence), which is exactly why Trinitrons looked so locked-in.
    if (MASK_TYPE == 1) conv.y *= 0.25;
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

    // Center-to-edge brightness falloff - the CRT "bulls-eye". The beam throws
    // farther to the corners and lands obliquely, spreading its energy, so they run
    // dimmer. Inherent tube geometry, not neglect: pro broadcast monitors were
    // speced near ~10% at the limit (EBU 3273/3320, +/-5% of mean), ordinary
    // consumer sets ran ~12-18% and budget worse. Here it lands ~10-14% at the
    // corner by default, up to ~18% on a cheap set, down to ~7-9% on a premium tube.
    // Age does NOT deepen this: the falloff is fixed geometry, and the overall age
    // dimming below scales the whole picture (corners and all) down together, so the
    // vignette just blends with the dimming at its built-in ratio. (If anything,
    // dose-driven phosphor wear concentrates in the heavily-used centre and flattens
    // the bulls-eye - but that needs a burn-in model we don't have, so uniform dims.)
    lin *= 1.0 - rad * rad * (0.12 + Hash(ft + 13.1) * 0.08) * priceVar;

    // --- Age: the slow revenge of time, piled on top no matter what you paid. ---
    // Leave a tube on long enough and the whole picture just gives up and dims
    // (~10-20% down by a decade, up to ~22% at 20 yrs) - unless it's a premium tube
    // riding its beam-current feedback, which props the brightness up for years.
    lin *= 1.0 - ageMech * 0.22;
    // Blue phosphor (ZnS:Ag) always tires first, green follows, red is the tough
    // one - so an old set slowly loses its blue, the whites go yellow and the whole
    // picture drifts warm and a touch jaundiced. A premium set's auto-cutoff loop
    // rebalances the drives to hold white longer (ageMech), so it yellows slower;
    // green wilts a little too, red hangs on.
    float blueWear = ageMech * (0.10 + Hash(ft + 14.2) * 0.10);  // ~10-20% blue loss at 20 yrs
    lin.b *= 1.0 - blueWear;
    lin.g *= 1.0 - blueWear * 0.4;
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
