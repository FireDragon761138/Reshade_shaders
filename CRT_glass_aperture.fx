/*=============================================================================

    CRT_glass_aperture.fx
    ----------------------------------------------------------------------------
    The aperture-grille sibling of CRT_glass_effects: the "glass" layer tuned for
    a premium aperture-grille tube (Sony Trinitron / Mitsubishi Diamondtron class)
    instead of a consumer shadow-mask set. Same two phenomena, different glass:

        * HALATION  -> the warm glow that bleeds out of bright areas. On these
                       tubes it is TIGHT and RESTRAINED: the dark "smoked"
                       faceplate that Trinitrons were known for is an anti-halation
                       feature - direct light crosses the tint once, halation
                       crosses it three times, so the halo is squared down to a
                       close bright-only glow. Contrast punch was the whole pitch.
        * DIFFRACTION-> the faint chromatic spread through the faceplate. The tube
                       is CYLINDRICAL - vertically flat, curved only across X - so
                       the spread runs HORIZONTALLY, not radially. Kept low:
                       Trinitron convergence was famously tight, so there is little
                       fringe to begin with; this is just the glass's own whisper.

    This is NOT scanline bloom and has no beam model - it glows the finished tube
    image. Run it after CRT_TV_Lite (set Mask Type = Aperture Grille, and a small
    Curvature X with Curvature Y = 0 for the cylindrical face), and before the
    bezel:

        NTSC_TV  ->  CRT_TV_Lite  ->  CRT_glass_aperture  ->  CRT_BezelBlur

    For an ordinary consumer shadow-mask TV use CRT_glass_effects instead; for a
    PC monitor you'd usually leave the glass layer off entirely. Don't run this
    and CRT_glass_effects together - they're two versions of the same layer.

    (No cheap-set path here: a budget clear-glass tube is the opposite of what
    this file models. See CRT_glass_effects' GLASS_CHEAP_SET for that.)

=============================================================================*/

#include "ReShade.fxh"

// Glow runs at a fraction of screen res - cheaper, and naturally softer.
#ifndef GRILLE_GLASS_DOWNSCALE
    #define GRILLE_GLASS_DOWNSCALE 4
#endif

// Blur taps each side of center. The dark-glass halo is tighter than a consumer
// set's, so it needs less reach - 6 covers it. Raise for a smoother glow.
#ifndef GRILLE_GLASS_SAMPLES
    #define GRILLE_GLASS_SAMPLES 6
#endif

// --------------------------------------------------------------------------
// Controls
// --------------------------------------------------------------------------
uniform float WetDry <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Dry / Wet";
    ui_tooltip = "Blend the whole glass effect against the clean image.\n"
                 "0 = off (dry), 1 = full effect (wet). The defaults are\n"
                 "calibrated at 1.0 - lower this to fade the whole layer.";
    ui_category = "Mix";
> = 1.0;

uniform float Threshold <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Glow Threshold";
    ui_tooltip = "How bright a pixel must be before it starts to glow.\n"
                 "Set high here: the dark faceplate suppresses the low-level haze,\n"
                 "so only genuine highlights halo. That's the Trinitron look -\n"
                 "clean blacks with tight bright glow, not an overall wash.";
    ui_category = "Glow";
> = 0.55;

uniform float Size <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Glow Size";
    ui_tooltip = "How far the glow spreads from bright areas.\n"
                 "Tighter than a consumer set: same glass thickness, but the dark\n"
                 "tint eats the faint outer skirt, so the visible halo reads close.";
    ui_category = "Glow";
> = 3.0;

uniform float Intensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Glow Intensity";
    ui_tooltip = "Strength of the glow added on top of the picture.\n"
                 "Low: the tinted faceplate attenuates the halo on all three of its\n"
                 "passes through the glass, so the glow is a restrained accent.";
    ui_category = "Glow";
> = 0.40;

uniform float3 HalationTint <
    ui_type = "color";
    ui_label = "Halation Tint";
    ui_tooltip = "Color the glow is pushed toward. Halation is physically warm\n"
                 "(long wavelengths scatter most), but the neutral-dark tint and\n"
                 "the cool ~9300K white point of these sets flatten the red bias,\n"
                 "so it leans only slightly warm.";
    ui_category = "Halation";
> = float3(1.0, 0.70, 0.62);

uniform float Warmth <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Halation Warmth";
    ui_tooltip = "How far the glow is tinted toward the halation color.\n"
                 "Kept modest: on a cool-white premium tube the halo should stay\n"
                 "close to neutral, not read as an orange bloom.";
    ui_category = "Halation";
> = 0.35;

uniform float Diffraction <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Diffraction (horizontal)";
    ui_tooltip = "Chromatic spread of the glow through the CYLINDRICAL faceplate.\n"
                 "Unlike a spherical consumer tube, a Trinitron is flat vertically,\n"
                 "so the spread runs horizontally only: red pushed out along X, blue\n"
                 "pulled in, growing toward the left/right edges. Kept low - these\n"
                 "tubes converged tight, so this is just the glass's own faint fringe.";
    ui_category = "Diffraction";
> = 0.12;

// --------------------------------------------------------------------------
// Downscaled ping-pong glow buffers (uniquely named so this can coexist with
// CRT_glass_effects' buffers in the same ReShade session).
// --------------------------------------------------------------------------
texture tGrilleGlassA { Width = BUFFER_WIDTH / GRILLE_GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GRILLE_GLASS_DOWNSCALE; Format = RGBA16F; };
texture tGrilleGlassB { Width = BUFFER_WIDTH / GRILLE_GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GRILLE_GLASS_DOWNSCALE; Format = RGBA16F; };

sampler sGrilleGlassA { Texture = tGrilleGlassA; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };
sampler sGrilleGlassB { Texture = tGrilleGlassB; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

// --------------------------------------------------------------------------
// Passes
// --------------------------------------------------------------------------

// 1) Keep only the bright part of the picture (soft knee), preserving its color.
//    Four bilinear taps at the quarter-points of the destination texel cover its
//    whole screen-pixel footprint - a true box filter, so the aperture grille's
//    vertical stripes can't alias a colour cast into the glow.
float3 PS_Prefilter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 q = ReShade::PixelSize * (GRILLE_GLASS_DOWNSCALE * 0.25);
    float3 c = 0.25 * (tex2D(ReShade::BackBuffer, uv + float2(-q.x, -q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2( q.x, -q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2(-q.x,  q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2( q.x,  q.y)).rgb);
    float  luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float  bright = max(luma - Threshold, 0.0) / max(1.0 - Threshold, 1e-3);
    return c * bright;
}

// Separable Gaussian shared by both blur passes. Step is measured in *screen*
// pixels per tap (downscale-independent look), clamped to 2 glow texels per tap
// so bilinear filtering never leaves gaps between taps (a "dotted" halo). Past
// the clamp, raise GRILLE_GLASS_SAMPLES or GRILLE_GLASS_DOWNSCALE to grow it.
float3 GaussianBlur(sampler s, float2 uv, float2 dir)
{
    float px = min(Size * (8.0 / 3.0), 2.0 * GRILLE_GLASS_DOWNSCALE);
    float2 step = ReShade::PixelSize * px * dir;

    const float sigma = GRILLE_GLASS_SAMPLES * 0.5;
    float3 sum = tex2D(s, uv).rgb;
    float  wsum = 1.0;

    [unroll]
    for (int i = 1; i <= GRILLE_GLASS_SAMPLES; i++)
    {
        float w = exp(-(i * i) / (2.0 * sigma * sigma));
        sum  += (tex2D(s, uv + step * i).rgb + tex2D(s, uv - step * i).rgb) * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

float3 PS_BlurH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGrilleGlassA, uv, float2(1.0, 0.0));
}

float3 PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGrilleGlassB, uv, float2(0.0, 1.0));
}

// 3) Add the glass on top of the scene.
float3 PS_Combine(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;

    // Diffraction: HORIZONTAL only (cylindrical faceplate). Scale the glow's X
    // coordinate about screen center per channel - red wider, blue tighter -
    // while leaving Y untouched, so the fringe grows toward the left/right edges
    // and vanishes vertically. Skipped at 0 (uniform branch, no divergence).
    float3 glow;
    if (Diffraction > 0.0)
    {
        float  dx = (uv.x - 0.5);
        float  d  = Diffraction * 0.015;
        float2 pr = float2(0.5 + dx * (1.0 + d), uv.y);   // red pushed outward
        float2 pb = float2(0.5 + dx * (1.0 - d), uv.y);   // blue pulled in
        glow.r = tex2D(sGrilleGlassA, pr).r;
        glow.g = tex2D(sGrilleGlassA, uv).g;
        glow.b = tex2D(sGrilleGlassA, pb).b;
    }
    else
    {
        glow = tex2D(sGrilleGlassA, uv).rgb;
    }

    // Halation: push the glow toward the warm tint.
    glow = lerp(glow, glow * HalationTint, Warmth);

    // Add the glass layer; soft (screen-ish) so highlights don't hard-clip.
    float3 add = glow * Intensity;
    float3 lit = 1.0 - (1.0 - scene) * (1.0 - saturate(add));

    return lerp(scene, lit, WetDry);
}

technique CRT_Glass_Aperture <
    ui_tooltip = "Halation + glass diffraction tuned for a premium aperture-grille\n"
                 "tube (Trinitron / Diamondtron class): tight dark-glass halo,\n"
                 "restrained warmth, horizontal-only fringe. Run AFTER CRT_TV_Lite\n"
                 "(Mask = Aperture Grille) and before CRT_BezelBlur. Use this OR\n"
                 "CRT_glass_effects, not both.";
>
{
    pass Prefilter { VertexShader = PostProcessVS; PixelShader = PS_Prefilter; RenderTarget = tGrilleGlassA; }
    pass BlurH     { VertexShader = PostProcessVS; PixelShader = PS_BlurH;     RenderTarget = tGrilleGlassB; }
    pass BlurV     { VertexShader = PostProcessVS; PixelShader = PS_BlurV;     RenderTarget = tGrilleGlassA; }
    pass Combine   { VertexShader = PostProcessVS; PixelShader = PS_Combine; }
}
