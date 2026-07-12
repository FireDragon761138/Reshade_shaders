/*=============================================================================

    CRT_glass_effects.fx
    ----------------------------------------------------------------------------
    A small, optional companion to CRT_TV_Lite. It fakes the two things that
    happen to light *inside the glass* of a real tube - and nothing else:

        * HALATION  -> the soft, warm/red glow that bleeds out of bright areas
                       as light scatters in the phosphor and back off the glass.
        * DIFFRACTION-> the faint chromatic spread light picks up passing through
                       the thick curved faceplate (red spreads wider than blue).

    This is NOT scanline bloom. There is no beam/scanline model here at all - it
    just takes whatever the picture already is and adds the glass on top. Run it
    *after* CRT_TV_Lite so it glows the finished tube image, and *before*
    CRT_BezelBlur so the bezel occludes the glow like a real rim would:

        NTSC_TV  ->  CRT_TV_Lite  ->  CRT_glass_effects  ->  CRT_BezelBlur

    How it works (cheap on purpose):
        1. Prefilter bright pixels into a downscaled buffer (soft threshold),
           box-filtered over the full footprint so the phosphor mask can't
           alias a colour cast into the glow.
        2. Separable Gaussian blur (one horizontal, one vertical pass).
        3. Combine: sample the glow per-channel with a tiny radial offset for
           diffraction, warm it for halation, add it back, then a Dry/Wet blend.

    THE DEFAULTS are calibrated to an average decent American/Japanese
    shadow-mask consumer TV of the early 1990s (a 20-27" Panasonic / Toshiba /
    Zenith class set). Those tubes had a gray "smoked" faceplate: direct picture
    light crosses the tint once but halation crosses it three times, so the halo
    stays warm, close and controlled. Halo radius comes from the glass thickness
    (~2x a ~12mm faceplate = ~20mm, ~5% of picture height on a 27").
    For a PC-monitor emulation you'd mostly leave this effect OFF - monitor
    glass was thinner, darker and often coated, so its halation barely reads.

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
// 8 fully covers the consumer-TV halo width the defaults are tuned to.
#ifndef GLASS_SAMPLES
    #define GLASS_SAMPLES 8
#endif

// The bargain-bin set. Decent tubes paid for gray "smoked" faceplate glass;
// budget tubes shipped clearer glass instead (tint costs brightness, and
// brightness sold TVs on the showroom floor). Clear glass scatters a slice of
// ALL bright light across a wide radius - VEILING GLARE - so blacks lift into
// a milky haze around the picture, the halo runs hotter, and the sloppier
// curved faceplate fringes colours about twice as hard. Costs two extra blur
// passes (compiled out entirely when off). 0 = decent set (default).
#ifndef GLASS_CHEAP_SET
    #define GLASS_CHEAP_SET 0
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
                 "Lower = more of the picture blooms. Real glass scatters a\n"
                 "fraction of ALL light, not just highlights, so a lowish\n"
                 "threshold reads truer than a strict highlights-only one.";
    ui_category = "Glow";
> = 0.40;

uniform float Size <
    ui_type = "slider";
    ui_min = 0.5; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Glow Size";
    ui_tooltip = "How far the glow spreads from bright areas.\n"
                 "3.5 matches the ~20mm halo a ~12mm consumer faceplate throws\n"
                 "(scaled to picture height).";
    ui_category = "Glow";
> = 3.5;

uniform float Intensity <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 3.0; ui_step = 0.01;
    ui_label = "Glow Intensity";
    ui_tooltip = "Strength of the glow added on top of the picture.\n"
                 "The tinted faceplate of a decent set eats the halo twice\n"
                 "over, so keep this modest - a few percent of emitted light.";
    ui_category = "Glow";
> = 0.70;

uniform float3 HalationTint <
    ui_type = "color";
    ui_label = "Halation Tint";
    ui_tooltip = "Color the glow is pushed toward. Real halation is warm/red\n"
                 "because long wavelengths scatter and penetrate the glass most;\n"
                 "the neutral-gray tint of a decent faceplate mutes the bias.";
    ui_category = "Halation";
> = float3(1.0, 0.60, 0.45);

uniform float Warmth <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Halation Warmth";
    ui_tooltip = "How far the glow is tinted toward the halation color.\n"
                 "0 = keep the source color, 1 = fully tinted. Around 0.55\n"
                 "white highlights halo warm-white rather than orange.";
    ui_category = "Halation";
> = 0.55;

#if GLASS_CHEAP_SET
uniform float Diffraction <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Diffraction";
    ui_tooltip = "Chromatic spread of the glow through the cheap clear faceplate:\n"
                 "red pushed outward, blue pulled in, reading on high-contrast edges\n"
                 "toward the borders. A budget tube's sloppy glass genuinely fringes\n"
                 "this much. On a decent set this control is compiled out - the tube's\n"
                 "gun convergence (CRT_TV_Lite Factory Tuning) carries the visible\n"
                 "fringe and glass dispersion is an invisible whisper.\n"
                 "(Part of GLASS_CHEAP_SET.)";
    ui_category = "Cheap Set";
> = 0.22;
#endif

#if GLASS_CHEAP_SET
uniform float Veil <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Veiling Glare";
    ui_tooltip = "The broad milky haze of cheap clear faceplate glass: a slice\n"
                 "of all bright light scattered wide, lifting the blacks around\n"
                 "the picture. The signature look of a budget tube.\n"
                 "(Part of GLASS_CHEAP_SET.)";
    ui_category = "Cheap Set";
> = 0.35;
#endif

// --------------------------------------------------------------------------
// Downscaled ping-pong glow buffers
// --------------------------------------------------------------------------
texture tGlassA { Width = BUFFER_WIDTH / GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GLASS_DOWNSCALE; Format = RGBA16F; };
texture tGlassB { Width = BUFFER_WIDTH / GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GLASS_DOWNSCALE; Format = RGBA16F; };

sampler sGlassA { Texture = tGlassA; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };
sampler sGlassB { Texture = tGlassB; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };

#if GLASS_CHEAP_SET
// Third buffer so the wide veil doesn't clobber the tight halo in tGlassA.
texture tGlassC { Width = BUFFER_WIDTH / GLASS_DOWNSCALE; Height = BUFFER_HEIGHT / GLASS_DOWNSCALE; Format = RGBA16F; };
sampler sGlassC { Texture = tGlassC; AddressU = CLAMP; AddressV = CLAMP; MagFilter = LINEAR; MinFilter = LINEAR; };
#endif

// --------------------------------------------------------------------------
// Passes
// --------------------------------------------------------------------------

// 1) Keep only the bright part of the picture (soft knee), preserving its color.
//    Four bilinear taps at the quarter-points of the destination texel cover its
//    whole screen-pixel footprint (each tap averages a distinct 2x2 at the
//    default 4x downscale) - a true box filter, so the 1px phosphor mask and
//    scanline pattern average out instead of aliasing a colour cast into the glow.
float3 PS_Prefilter(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 q = ReShade::PixelSize * (GLASS_DOWNSCALE * 0.25);
    float3 c = 0.25 * (tex2D(ReShade::BackBuffer, uv + float2(-q.x, -q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2( q.x, -q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2(-q.x,  q.y)).rgb
                     + tex2D(ReShade::BackBuffer, uv + float2( q.x,  q.y)).rgb);
    float  luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    float  bright = max(luma - Threshold, 0.0) / max(1.0 - Threshold, 1e-3);
    return c * bright;
}

// Separable Gaussian shared by all blur passes.
float3 GaussianBlur(sampler s, float2 uv, float2 dir, float scale)
{
    // Step is measured in *screen* pixels per tap, independent of the glow
    // buffer's downscale, so changing GLASS_DOWNSCALE (or the tap count) won't
    // rescale the look - "Size" keeps meaning the same spread. The 8/3 factor
    // keeps total reach matched to the old 8-tap / half-res version.
    // Clamped to 2 glow texels per tap: bilinear filtering can only bridge that
    // far before the taps read as separate lobes (a "dotted" halo around small
    // highlights). Past the clamp, raise GLASS_SAMPLES (more taps) or
    // GLASS_DOWNSCALE (coarser, cheaper buffer) to grow the glow further.
    // Wider cascaded stages (the cheap-set veil) sample already-blurred content,
    // so their clamp scales up with them.
    float px = min(Size * (8.0 / 3.0), 2.0 * GLASS_DOWNSCALE) * scale;
    float2 step = ReShade::PixelSize * px * dir;

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
    return GaussianBlur(sGlassA, uv, float2(1.0, 0.0), 1.0);
}

float3 PS_BlurV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGlassB, uv, float2(0.0, 1.0), 1.0);
}

#if GLASS_CHEAP_SET
// Veil cascade: re-blur the finished halo 4x wider. Cascading off the already
// smooth halo keeps the sparse taps artifact-free and lands a haze roughly
// 4-5x the halo radius - the screen-wide wash of clear budget glass.
float3 PS_VeilH(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGlassA, uv, float2(1.0, 0.0), 4.0);
}

float3 PS_VeilV(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return GaussianBlur(sGlassB, uv, float2(0.0, 1.0), 4.0);
}
#endif

// 3) Add the glass on top of the scene.
float3 PS_Combine(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;

#if GLASS_CHEAP_SET
    // Cheap clear faceplate: real, visible chromatic spread. Sample the glow per
    // channel with a tiny radial scale around screen center - red pushed wider,
    // blue pulled in. Skipped at 0 (uniform branch - every pixel takes the same
    // path, no divergence).
    float3 glow;
    if (Diffraction > 0.0)
    {
        float2 dir = uv - 0.5;
        float  d = Diffraction * 0.015;
        glow.r = tex2D(sGlassA, 0.5 + dir * (1.0 + d)).r;
        glow.g = tex2D(sGlassA, uv).g;
        glow.b = tex2D(sGlassA, 0.5 + dir * (1.0 - d)).b;
    }
    else
    {
        glow = tex2D(sGlassA, uv).rgb;
    }

    // Veiling glare rides on top of the halo and through the same tint below,
    // so the haze warms the way the halo does.
    glow += tex2D(sGlassC, uv).rgb * Veil;
#else
    // Decent set: no glass diffraction. The tube's gun convergence carries the
    // visible fringe, so this pass always takes the single-fetch fast path
    // (~30% off the whole effect vs. the 3-fetch chromatic sampling).
    float3 glow = tex2D(sGlassA, uv).rgb;
#endif

    // Halation: push the glow toward the warm tint.
    glow = lerp(glow, glow * HalationTint, Warmth);

    // Add the glass layer; soft (screen-ish) so highlights don't hard-clip.
    float3 add = glow * Intensity;
    float3 lit = 1.0 - (1.0 - scene) * (1.0 - saturate(add));

    return lerp(scene, lit, WetDry);
}

technique CRT_Glass_Effects <
    ui_tooltip = "Halation + glass diffraction layer, tuned to an early-90s\n"
                 "shadow-mask consumer TV. Run AFTER CRT_TV_Lite (and before\n"
                 "CRT_BezelBlur). Not scanline bloom - just the glow through\n"
                 "the tube glass.";
>
{
    pass Prefilter { VertexShader = PostProcessVS; PixelShader = PS_Prefilter; RenderTarget = tGlassA; }
    pass BlurH     { VertexShader = PostProcessVS; PixelShader = PS_BlurH;     RenderTarget = tGlassB; }
    pass BlurV     { VertexShader = PostProcessVS; PixelShader = PS_BlurV;     RenderTarget = tGlassA; }
#if GLASS_CHEAP_SET
    pass VeilH     { VertexShader = PostProcessVS; PixelShader = PS_VeilH;     RenderTarget = tGlassB; }
    pass VeilV     { VertexShader = PostProcessVS; PixelShader = PS_VeilV;     RenderTarget = tGlassC; }
#endif
    pass Combine   { VertexShader = PostProcessVS; PixelShader = PS_Combine; }
}
