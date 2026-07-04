/*=============================================================================

    NTSC_Blur.fx
    ----------------------------------------------------------------------------
    A small, artistic stand-in for NTSC_TV.fx. Where NTSC_TV models the actual
    composite signal (dot crawl, cross-color rainbows, subcarrier), this just
    captures the *look* an analog NTSC signal leaves behind: a horizontal smear
    where color bleeds sideways much further than brightness.

    That asymmetry is the whole trick. On a real NTSC line the chroma carries
    far less bandwidth than the luma, so colors run and fringe horizontally
    while edges and brightness stay comparatively crisp. We reproduce it with
    one cheap horizontal pass:

        1. Convert each tap to YIQ (luma + two chroma axes).
        2. Blur Y narrowly (keeps detail), blur I/Q widely (the color bleed).
        3. Convert back to RGB and Dry/Wet blend.

    The chroma smear also leans RIGHT (the scan direction): NTSC chroma is a
    causal, left-to-right filter, so colour trails rather than spreading evenly
    (the Chroma Trail control).

    TWO SIGNAL PATHS, chosen by NTSC_SVIDEO (a self-contained subsystem each):
      * Composite (default) - combined Y/C: softer luma, and with NTSC_ADVANCED
        the crawling "dot crawl" from imperfect Y/C separation.
      * S-Video             - separate Y/C: sharp luma, no dot crawl, colour still
        bleeds. The "sharp picture, soft colour" look.

    Horizontal only by design - vertical detail is left for the scanlines that
    come later. Put it BEFORE the CRT pass so the tube draws over the softened image:

        NTSC_Blur  ->  CRT_TV_Lite

    Use it instead of NTSC_TV when you want the soft analog feel without the
    full signal simulation (and a fraction of the cost).

=============================================================================*/

#include "ReShade.fxh"

// Taps each side of center. More = smoother bleed, slightly slower. Bump this if
// you push Chroma Bleed very high and the smear starts to look stepped.
#ifndef NTSC_BLUR_SAMPLES
    #define NTSC_BLUR_SAMPLES 10
#endif

// ---- Signal type (selects which subsystem / path is compiled) -------------
// 0 = Composite (default): the combined-signal look - chroma bleed, plus (with
//     NTSC_ADVANCED) dot crawl from imperfect Y/C separation.
// 1 = S-Video (separate Y/C): luma and chroma ride their own wires, so they never
//     cross-contaminate - luma stays sharp (composite notches it around the 3.58MHz
//     subcarrier; S-Video keeps full bandwidth) and there is NO dot crawl. Colour
//     still bleeds sideways though - chroma bandwidth is identical to composite -
//     giving S-Video's signature "sharp picture, soft colour" look. This compiles a
//     wholly separate path; none of the composite/dot-crawl code is built.
#ifndef NTSC_SVIDEO
    #define NTSC_SVIDEO 0
#endif

// ---- Advanced feature set (COMPOSITE path only) ---------------------------
// 0 = basic model only (sharp-luma / wide-chroma smear + rightward chroma trail).
// 1 = adds dot crawl - the crawling checkerboard composite leaves along colour
//     edges. Only meaningful on the composite path; S-Video has no dot crawl.
#ifndef NTSC_ADVANCED
    #define NTSC_ADVANCED 0
#endif

// --------------------------------------------------------------------------
// Shared controls (both paths)
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
    ui_tooltip = "How far color smears horizontally - the main NTSC 'look'.\n"
                 "In pixels at 1080p; scales with your resolution and assumes a 4:3\n"
                 "NTSC frame, so the smear holds its apparent width on any display.";
    ui_category = "NTSC Blur";
> = 6.0;

uniform float LumaBlur <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 6.0; ui_step = 0.1;
    ui_label = "Luma Softness";
    ui_tooltip = "Horizontal softness of brightness/detail. In pixels at 1080p,\n"
                 "scales with resolution and is 4:3-relative like Chroma Bleed.\n"
                 "Keep this well below Chroma Bleed - sharp luma, soft color\n"
                 "is what sells the analog look. (S-Video runs it ~2x sharper.)";
    ui_category = "NTSC Blur";
> = 1.0;

uniform float ChromaTrail <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Chroma Trail";
    ui_tooltip = "Rightward smear asymmetry. Real NTSC chroma trails in the scan\n"
                 "direction (to the right), not evenly both ways, because it's a\n"
                 "causal filter running left-to-right along each line.\n"
                 "0 = symmetric bleed; higher = stronger rightward lean.";
    ui_category = "NTSC Blur";
> = 0.3;

// --------------------------------------------------------------------------
// YIQ <-> RGB (standard NTSC matrices) - shared
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
// Shared horizontal YIQ blur: narrow luma (sigmaL) + wide chroma (ChromaBleed)
// with the rightward Chroma Trail. Both paths call this; only the luma width they
// ask for differs (composite softer, S-Video sharper). Returns blurred YIQ.
// --------------------------------------------------------------------------
float3 BlurYIQ(float2 uv, float sigmaL, float3 center)
{
    // Horizontal bleed is a fixed fraction of the 4:3 NTSC picture width, so it scales
    // with the buffer (via height) and assumes a 4:3 frame - NOT the display's actual
    // aspect. Slider values are pixels in a 1080-line 4:3 frame; height/1080 keeps
    // 1080p unchanged and holds the smear's apparent width at any resolution/aspect.
    float res      = BUFFER_HEIGHT / 1080.0;
    float bleed    = ChromaBleed * res;
    sigmaL         = max(sigmaL * res, 1e-3);
    float sigmaC   = max(bleed * 0.5, 1e-3);
    // Tap reach covers the WIDER of the two blurs (out to luma's ~3 sigma), so the
    // luma pass is still sampled when Chroma Bleed is small or zero. Luma and chroma
    // SHARE these taps, so at very high Chroma Bleed the spacing widens and the narrow
    // luma Gaussian starts to undersample - raise NTSC_BLUR_SAMPLES if luma ever looks
    // stepped. (Separate luma/chroma loops would fix it but double the texture fetches,
    // not worth it for this cheap stand-in.)
    float reach    = max(bleed, sigmaL * 3.0);
    float pxPerTap = reach / NTSC_BLUR_SAMPLES;

    float3 c0 = RGBtoYIQ(center);   // reuse the centre texel the caller already fetched (no re-sample)
    float  sumY  = c0.x;   float  wY = 1.0;
    float2 sumIQ = c0.yz;  float  wC = 1.0;

    [unroll]
    for (int i = 1; i <= NTSC_BLUR_SAMPLES; i++)
    {
        float d  = i * pxPerTap;                                // distance in px
        float gL = exp(-(d * d) / (2.0 * sigmaL * sigmaL));
        float gC = exp(-(d * d) / (2.0 * sigmaC * sigmaC));

        float2 off = float2(d * ReShade::PixelSize.x, 0.0);
        float3 l = RGBtoYIQ(tex2D(ReShade::BackBuffer, uv - off).rgb);   // left neighbour
        float3 r = RGBtoYIQ(tex2D(ReShade::BackBuffer, uv + off).rgb);   // right neighbour

        // Luma stays symmetric - brightness/detail doesn't lean.
        sumY  += (l.x + r.x) * gL;  wY += 2.0 * gL;

        // Chroma leans on the LEFT neighbours, so colour is pulled in from the left
        // and trails to the RIGHT (the scan direction), like real NTSC chroma.
        float wL = gC * (1.0 + ChromaTrail);
        float wR = gC * (1.0 - ChromaTrail);
        sumIQ += l.yz * wL + r.yz * wR;  wC += wL + wR;
    }
    return float3(sumY / wY, sumIQ / wC);
}

#if NTSC_ADVANCED
// ---- Analog grit (SHARED - applies to both composite and S-Video) ----------
// It's signal-path noise (cables, transmission, tape), present on any analog feed,
// so unlike dot crawl it belongs to both subsystems.
uniform float timer < source = "timer"; >;   // ms since start - drives grit re-roll and the crawl

uniform float AnalogNoise <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Analog Warmth";
    ui_tooltip = "That analog 'warmth' - which is really the organic grain and noise a\n"
                 "real feed always has. Fine white luma grain plus coarser COLOURED\n"
                 "chroma noise that streaks horizontally and shows worst in dark areas\n"
                 "(the composite/VHS look). On composite AND S-Video, but S-Video is\n"
                 "cleaner - much less colour noise (it skips the demod that adds it) and\n"
                 "slightly less grain. Signal-path noise, not a Y/C artifact. 0 = pristine.";
    ui_category = "Advanced (analog signal)";
> = 0.35;

// Cheap hash in [0,1].
float Hash21(float2 p) { return frac(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }

// Grit on the final YIQ, shared by both paths: fine luma grain + coarse coloured
// chroma streaks (worst in the dark). Cells are 1080p-referenced so the grain holds
// apparent size across resolutions, and it re-rolls at ~60 Hz (field rate) so it
// reads as live noise, not a frozen texture overlay. lumaMul/chromaMul let each path
// set its own level: S-Video is cleaner - a LOT on chroma (it skips the composite
// demodulation that adds most of the colour noise), a little on luma.
float3 ApplyGrit(float3 yiq, float2 vpos, float lumaMul, float chromaMul)
{
    if (AnalogNoise <= 0.0) return yiq;
    float res = BUFFER_HEIGHT / 1080.0;
    float ts  = floor(timer * 0.06);                      // ~60 Hz re-roll (field rate)
    ts       -= floor(ts / 1024.0) * 1024.0;              // wrap to [0,1024) for hash precision (manual mod)

    // Fine luma grain - monochrome, uniform.
    float2 gp = floor(vpos / res);
    yiq.x += (Hash21(gp + ts) - 0.5) * AnalogNoise * lumaMul * 0.10;

    // Coarse coloured chroma streaks (low chroma bandwidth -> ~3px horizontal cells),
    // worst in the dark - the composite/VHS colour-speckle look.
    float  dark = saturate(1.1 - yiq.x);
    float2 cp   = float2(floor(vpos.x / (3.0 * res)), floor(vpos.y / res)) + ts;
    float2 cn   = float2(Hash21(cp) - 0.5, Hash21(cp + 19.7) - 0.5);
    yiq.yz += cn * AnalogNoise * chromaMul * 0.20 * dark;

    return yiq;
}
#endif  // NTSC_ADVANCED

#if NTSC_SVIDEO
// ============================================================================
//  S-VIDEO SUBSYSTEM  (separate Y/C - its own path)
//  Luma and chroma never cross, so luma keeps full bandwidth (sharp) and there is
//  no dot crawl at all. Chroma still bleeds - its bandwidth matches composite.
// ============================================================================
float3 PS_NTSCBlur(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 yiq  = BlurYIQ(uv, LumaBlur * 0.5, orig);   // full-bandwidth luma: ~2x sharper than composite
#if NTSC_ADVANCED
    yiq = ApplyGrit(yiq, pos.xy, 0.75, 0.35);          // S-Video: cleaner - esp. chroma (no demod noise)
#endif
    return lerp(orig, saturate(YIQtoRGB(yiq)), Strength);
}

#else
// ============================================================================
//  COMPOSITE SUBSYSTEM  (combined Y/C - its own path)
//  Luma is softened by the subcarrier notch, and - with NTSC_ADVANCED - leftover
//  chroma leaks back into luma as crawling "dot crawl". All dot-crawl code and its
//  controls live here; the S-Video path above never sees them.
// ============================================================================
#if NTSC_ADVANCED
// Colour-subcarrier cycles across the picture width. Real NTSC is 227.5 cycles per
// active line; that half-cycle is exactly what flips the dot phase 180 deg each
// line. Leave at 227.5 for authentic dot pitch - it scales with resolution itself.
#ifndef NTSC_SUBCARRIER_CYCLES
    #define NTSC_SUBCARRIER_CYCLES 227.5
#endif

uniform float DotCrawlLines <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1080.0; ui_step = 1.0;
    ui_label = "Scanlines";
    ui_tooltip = "Signal lines the dot-crawl checkerboard flips across - its vertical\n"
                 "scale (it flips phase once per scanline). Match this to CRT_TV_Lite's\n"
                 "Scanline Count so the dots stay locked to the tube's scanlines.\n"
                 "0 = Auto: ~1/4 screen height (~4px) - the same rule CRT_TV_Lite's auto\n"
                 "scanlines use, so leaving both on Auto keeps them matched, no setup.\n"
                 "Or pin a count: 240 (240p / PSX-era), 480 (480i / PS2-era).";
    ui_category = "Advanced (composite signal)";
> = 0.0;

uniform float DotCrawl <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Dot Crawl";
    ui_tooltip = "The infamous composite artifact: chroma the set couldn't fully\n"
                 "separate from luma leaks back as a fine checkerboard of dots along\n"
                 "colour edges, flipping phase every line and field so it appears to\n"
                 "crawl. Strongest at saturated horizontal colour boundaries.\n"
                 "Vertically it tracks the tube's scanlines - see the Scanlines control.\n"
                 "0 = off. Composite only (S-Video separates Y/C, so it has none).";
    ui_category = "Advanced (composite signal)";
> = 0.5;
#endif  // NTSC_ADVANCED

float3 PS_NTSCBlur(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 orig = tex2D(ReShade::BackBuffer, uv).rgb;
    float3 yiq  = BlurYIQ(uv, LumaBlur, orig);   // composite softens luma (subcarrier notch)

#if NTSC_ADVANCED
    // ---- Dot crawl (composite only) --------------------------------------
    // Composite couldn't fully separate chroma from luma, so leftover chroma rides
    // back into luma as a subcarrier checkerboard. The subcarrier flips 180 deg per
    // scanline AND per field (NTSC's 227.5 cycles/line), which is what makes the
    // dots crawl. We concentrate it at horizontal colour edges (hanging dots), where
    // separation fails worst, scaled by how saturated the colour is.
    if (DotCrawl > 0.0)
    {
        // Vertical scale = one phase flip per scanline, using CRT_TV_Lite's exact
        // Scanline Count rule (Auto = ~1/4 screen height / ~4px), so the dots stay
        // locked to the tube's scanlines at any resolution.
        float lines = (DotCrawlLines < 1.0) ? BUFFER_HEIGHT * 0.25
                                            : DotCrawlLines;

        // Chroma edge across one signal line -> hanging dots concentrate at colour
        // boundaries (offset is 1/lines, i.e. one scanline), scaled by how saturated
        // the colour is.
        float3 up   = RGBtoYIQ(tex2D(ReShade::BackBuffer, uv - float2(0.0, 1.0 / lines)).rgb);
        float  edge = length(yiq.yz - up.yz);          // vertical chroma transition
        float  sat  = length(yiq.yz);                  // chroma available to leak
        float  leak = saturate(sat * 0.5 + edge * 3.0);

        // Crawl the pattern UPWARD over time. A per-frame 180-deg flip would make
        // consecutive frames exact inverses, averaging to zero in motion (invisible).
        // Instead we slide the vertical phase with real time so the dots climb, like
        // real dot crawl, and never cancel. Driven by "timer" (real ms), NOT frame
        // count: a composite signal's dot crawl is paced by the field rate, so it
        // must not speed up or slow down with the game's FPS (and it keeps crawling
        // on a paused frame). ~10 lines/s up. The 0.5*vline term still gives the
        // 180-deg-per-line checkerboard flip.
        float vline = pos.y * lines / BUFFER_HEIGHT;                      // scanline coordinate
        // Subcarrier spans the 4:3 NTSC active LINE, not the raw (maybe 16:9) buffer -
        // derive that width from the buffer height * 4/3. 227.5 cyc per 4:3 line.
        float phase = (pos.x / (BUFFER_HEIGHT * 4.0 / 3.0)) * NTSC_SUBCARRIER_CYCLES  // horizontal subcarrier
                    + 0.5 * (vline + timer * 0.01);                                   // per-line flip + upward crawl
        float dots  = cos(6.2831853 * phase);

        yiq.x += dots * leak * DotCrawl * 0.5;         // luminance beat: ~25% swing at the 0.5
                                                       // default, up to ~50% (intense) at 1.0
    }

    yiq = ApplyGrit(yiq, pos.xy, 1.0, 1.0);            // composite: full grit (luma + noisy chroma)
#endif  // NTSC_ADVANCED

    return lerp(orig, saturate(YIQtoRGB(yiq)), Strength);
}
#endif  // NTSC_SVIDEO

technique NTSC_Blur <
    ui_tooltip = "Artistic analog-video smear: horizontal chroma bleed with sharp\n"
                 "luma. Composite or S-Video path via NTSC_SVIDEO. A light stand-in\n"
                 "for NTSC_TV - run BEFORE CRT_TV_Lite.";
>
{
    pass { VertexShader = PostProcessVS; PixelShader = PS_NTSCBlur; }
}
