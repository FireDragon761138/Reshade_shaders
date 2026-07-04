/*=============================================================================

    VHS_Lite.fx  --  lightweight VHS tape degradation (resolution + artifacts)

    Models what a VHS tape does to an already-composite signal: it does NOT
    redo composite chroma bleed (that's NTSC_Blur's job) or the display
    (CRT shader's job). This is the TAPE stage.

    Chain order:  Broadcast80s -> NTSC_Blur -> **VHS_Lite** -> CRT

    ONE master lever: Tape Wear (0 = a clean fresh cassette, 1 = a worn-out
    tape that's been played to death). Real tapes degrade in a consistent
    ORDER, so Wear drives each effect through its own onset curve:
      - softness comes on first (VHS is never truly sharp),
      - then snow (shadow-biased noise),
      - then dropouts and tracking wobble (accelerating, late),
      - color fade throughout (reds & blues fade first -> faded green cast),
      - the tracking-noise band only shows up on a badly worn tape.
    The per-effect sliders are TRIMS (x1.0 = the wear-derived amount).

    Design goals: single pass, constant cost, well under 0.5 ms at 1080p.
    Resolution loss is a fixed 9-tap HORIZONTAL low-pass; the slider scales tap
    SPACING not COUNT, so GPU cost never changes. Animates off ReShade's timer.
    BSD-2-Clause.

=============================================================================*/

#include "ReShade.fxh"

// Dropout quality. 0 = Basic (single desynced held-line smear). 1 = High
// Quality (dual-mode: uncompensated white-level "comet" streaks + a 7-tap
// luma-held DOC smear -- research-accurate, costs a few more taps in-branch).
#ifndef VHS_HIGH_QUALITY
#define VHS_HIGH_QUALITY 0
#endif

uniform float Timer < source = "timer"; >;

//-----------------------------------------------------------------------------
// MASTER
//-----------------------------------------------------------------------------

uniform float TapeWear <
    ui_type = "slider";
    ui_label = "Tape Wear";
    ui_tooltip = "The one lever. 0 = fresh cassette, 1 = played-to-death.\0Drives softness, snow, dropouts, wobble, tracking and color fade\0through realistic onset curves.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Master";
> = 0.4;

uniform float EffectStrength <
    ui_type = "slider";
    ui_label = "Effect Strength";
    ui_tooltip = "Blend the whole VHS look over the clean image. 1 = full.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Master";
> = 1.0;

//-----------------------------------------------------------------------------
// WEAR BALANCE (trims on the wear-derived amounts; 1.0 = as Wear dictates)
//-----------------------------------------------------------------------------

uniform float SoftnessTrim <
    ui_type = "slider";
    ui_label = "Softness Trim";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Wear Balance";
> = 1.0;

uniform float NoiseTrim <
    ui_type = "slider";
    ui_label = "Noise Trim";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Wear Balance";
> = 1.0;

uniform float DropoutTrim <
    ui_type = "slider";
    ui_label = "Dropout Trim";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Wear Balance";
> = 1.0;

uniform float InstabilityTrim <
    ui_type = "slider";
    ui_label = "Instability Trim (wobble/tracking)";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Wear Balance";
> = 1.0;

uniform float FadeTrim <
    ui_type = "slider";
    ui_label = "Color Fade Trim";
    ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_category = "Wear Balance";
> = 1.0;

//-----------------------------------------------------------------------------
// CHARACTER (shape, not intensity)
//-----------------------------------------------------------------------------

uniform float HeadSwitchHeight <
    ui_type = "slider";
    ui_label = "Head-Switch Height (px)";
    ui_tooltip = "Height of the torn noisy band at the bottom (0 = off).\0Its visibility scales with Wear.\0";
    ui_min = 0.0; ui_max = 48.0; ui_step = 1.0;
    ui_category = "Character";
> = 16.0;

uniform float HeadSwitchShift <
    ui_type = "slider";
    ui_label = "Head-Switch Tear";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Character";
> = 0.5;

uniform float DropoutSoftness <
    ui_type = "slider";
    ui_label = "Dropout Softness";
    ui_tooltip = "Feathers streak edges and lowers peak brightness so dropouts\0blend into the background instead of sitting on top.\0";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Character";
> = 0.65;

uniform float TrackingSpeed <
    ui_type = "slider";
    ui_label = "Tracking Band Speed";
    ui_min = -1.0; ui_max = 1.0; ui_step = 0.01;
    ui_category = "Character";
> = 0.15;

//-----------------------------------------------------------------------------
// Cheap hashes
//-----------------------------------------------------------------------------

float hash11(float p)
{
    p = frac(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return frac(p);
}

float hash21(float2 p)
{
    float3 p3 = frac(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return frac((p3.x + p3.y) * p3.z);
}

float3 DropTap(float2 xy) { return tex2D(ReShade::BackBuffer, xy).rgb; }

//-----------------------------------------------------------------------------
// Main
//-----------------------------------------------------------------------------

float3 PS_VHS(float4 pos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float  t     = Timer * 0.001;                 // seconds
    float2 px    = ReShade::PixelSize;
    float3 orig  = tex2D(ReShade::BackBuffer, texcoord).rgb;

    float line   = floor(texcoord.y * BUFFER_HEIGHT);

    // ---- derive every amount from Tape Wear (see header for the ordering) ----
    float a = saturate(TapeWear);
    float softness = (1.2 + 2.3 * pow(a, 0.8)) * SoftnessTrim;      // present when fresh
    float noiseAmt = (0.02 + 0.15 * pow(a, 1.5)) * NoiseTrim;       // snow, accelerates
    float dropAmt  = (0.25 * pow(a, 2.0)) * DropoutTrim;           // late & accelerating
    float wobAmt   = (0.30 + 1.6 * pow(a, 1.5)) * InstabilityTrim;  // tracking wobble
    float trackAmt = saturate((a - 0.6) / 0.4) * 0.5 * InstabilityTrim; // only when worn
    float fadeAmt  = saturate(0.4 * pow(a, 1.3)) * FadeTrim;        // color fade
    float smearAmt = 0.10 + 0.30 * a;                              // vertical bleed
    float hsShift  = HeadSwitchShift * (0.5 + a);                  // tear worsens with wear

    // --- horizontal sampling coordinate: wobble + head-switch tear ---
    float2 uv = texcoord;

    float jitter = (hash21(float2(line, floor(t * 30.0))) - 0.5) * 2.0;
    float wave   = sin(texcoord.y * 9.0 + t * 2.3);
    uv.x += (jitter * 0.6 + wave * 0.4) * wobAmt * px.x * 6.0;

    float bandFrac   = HeadSwitchHeight * px.y;
    float fromBottom = 1.0 - texcoord.y;
    float hsMask = (bandFrac > 0.0) ? saturate(1.0 - fromBottom / max(bandFrac, 1e-5)) : 0.0;
    uv.x += hsMask * hsMask * hsShift * (hash21(float2(line, floor(t * 20.0))) - 0.2);

    // --- resolution loss: fixed 9-tap horizontal low-pass ---
    static const float w[9] = { 0.1353, 0.3247, 0.6065, 0.8825, 1.0,
                                0.8825, 0.6065, 0.3247, 0.1353 };
    float3 col = float3(0.0, 0.0, 0.0);
    float  wsum = 0.0;
    [unroll]
    for (int i = 0; i < 9; i++)
    {
        float off = (float(i) - 4.0) * softness * px.x;
        col  += w[i] * tex2D(ReShade::BackBuffer, float2(uv.x + off, uv.y)).rgb;
        wsum += w[i];
    }
    col /= wsum;

    // Vertical smear: brief downward bright-ghost from the line above.
    {
        float3 above = tex2D(ReShade::BackBuffer, float2(uv.x, uv.y - px.y)).rgb;
        col = lerp(col, max(col, above), smearAmt * 0.5);
    }

    // --- color fade: reds & blues lose vibrancy first -> faded green cast ---
    if (fadeAmt > 0.0)
    {
        float lf = dot(col, float3(0.299, 0.587, 0.114));
        float3 fw = saturate(float3(1.15, 0.65, 1.05) * fadeAmt);   // R,B fade faster than G
        col = lerp(col, float3(lf, lf, lf), fw);
    }

    // --- tracking noise band (only on a worn tape; scrolls vertically) ---
    if (trackAmt > 0.0)
    {
        float bandY = frac(t * TrackingSpeed);
        float d     = abs(texcoord.y - bandY);
        float m     = smoothstep(0.06, 0.0, d) * trackAmt;
        float tn    = hash21(texcoord * ReShade::ScreenSize + t * 90.0);
        col = lerp(col, float3(tn, tn, tn), m);
        uv.x += m * (tn - 0.5) * 0.05;
    }

    // --- luma snow: shadow-biased additive noise ---
    float luma = dot(col, float3(0.299, 0.587, 0.114));
    float n    = hash21(texcoord * ReShade::ScreenSize + float2(t * 63.0, t * 41.0)) - 0.5;
    col += n * noiseAmt * lerp(1.6, 0.35, saturate(luma));

    // Head-switch band gets its own harsh noise + brightening.
    if (hsMask > 0.0)
    {
        float hn = hash21(texcoord * ReShade::ScreenSize + t * 120.0);
        float hv = hn * 0.9 + 0.1;
        col = lerp(col, float3(hv, hv, hv), hsMask * (0.4 + 0.4 * a));
    }

    // --- tape dropouts: two authentic modes, briefly & independently flashed ---
    // Research: dropouts are 1-15 us losses (~2-28% of a scanline) from shed
    // oxide, Poisson-distributed. UNCOMPENSATED they read as WHITE-LEVEL streaks
    // / "comets"; a deck's dropout compensator instead HOLDS THE PREVIOUS LINE's
    // LUMA (1H prior), which blends because adjacent lines are correlated. Real
    // footage is a mix of both, so we model both.
    if (dropAmt > 0.0)
    {
        float slots = 90.0;
        float slot  = floor(texcoord.y * slots);

        // Independent per-slot timing so dropouts don't snap on a global clock.
        float rate = 15.0;                           // ~67 ms windows
        float ph   = hash11(slot * 1.37);            // per-slot phase (desync)
        float ts   = t * rate + ph;
        float k    = floor(ts);
        float f    = frac(ts);

        float r = hash21(float2(slot, k));
        if (r < dropAmt)
        {
#if VHS_HIGH_QUALITY
            float2 np = texcoord * ReShade::ScreenSize + k * 3.1;

            // ~28% are uncompensated bright streaks (the visible sparkle); the
            // rest are compensated held-line smears that blend in.
            bool  white = hash21(float2(slot, k + 31.0)) < 0.28;

            // Brief flash: abrupt onset, quick fade (white ones even briefer).
            float duty = white ? 0.22 : 0.40;
            float env  = saturate(1.0 - f / duty); env *= env;

            // Region geometry (white streaks are thin, ~1-3 px; DOC a few more).
            float yc  = (slot + hash21(float2(slot, k + 5.0))) / slots;
            float rv  = hash21(float2(slot, k + 9.0));
            float vpx = (white ? (1.0 + 2.0 * rv) : (3.0 + 8.0 * rv)) * px.y;
            float vmask = smoothstep(vpx, 0.0, abs(texcoord.y - yc));

            // Horizontal extent: 1-15 us => ~2-28% of the line, biased short.
            float sx   = hash21(float2(slot, k + 7.0));
            float lr   = hash21(float2(slot, k + 13.0));
            float len  = white ? (0.02 + 0.10 * lr * lr) : (0.04 + 0.24 * lr * lr);
            float xrel = texcoord.x - sx;

            float hmask;
            if (white)
            {
                // "Comet": feathered bright head + fading horizontal tail.
                float head = smoothstep(0.0, 0.006, xrel);
                float tail = pow(saturate(1.0 - xrel / max(len, 1e-4)), 1.2);
                hmask = head * tail;
            }
            else
            {
                hmask = smoothstep(0.0, 0.05, xrel) * smoothstep(0.0, 0.05, len - xrel);
            }

            float mask = vmask * hmask * env;
            if (mask > 0.001)
            {
                float3 s;
                float3 spk = float3(hash21(np + 1.0), hash21(np + 2.0), hash21(np + 3.0)) - 0.5;

                if (white)
                {
                    // Uncompensated white-level substitution (softenable to blend).
                    float wp = lerp(1.0, 0.80, DropoutSoftness);
                    s = float3(wp, wp, wp) + spk * 0.05;
                }
                else
                {
                    // DOC hold: previous intact line, stretched (7-tap) and pulled
                    // left, then luma-biased (the compensator substitutes luma).
                    float srcY = yc - vpx - px.y;
                    float cx   = uv.x - 3.0 * px.x;
                    float sp   = 3.0 * px.x;
                    s = 0.06 * DropTap(float2(cx - 3.0 * sp, srcY))
                      + 0.12 * DropTap(float2(cx - 2.0 * sp, srcY))
                      + 0.18 * DropTap(float2(cx -       sp, srcY))
                      + 0.28 * DropTap(float2(cx,            srcY))
                      + 0.18 * DropTap(float2(cx +       sp, srcY))
                      + 0.12 * DropTap(float2(cx + 2.0 * sp, srcY))
                      + 0.06 * DropTap(float2(cx + 3.0 * sp, srcY));
                    float sl = dot(s, float3(0.299, 0.587, 0.114));
                    s = lerp(s, float3(sl, sl, sl), 0.65);                       // luma
                    s = lerp(s, float3(1.0, 1.0, 1.0), lerp(0.16, 0.05, DropoutSoftness));
                    s += spk * 0.04;
                }

                float strength = (0.55 + 0.35 * hash21(float2(slot, k + 3.0)))
                               * lerp(0.9, 0.55, DropoutSoftness);
                col = lerp(col, s, saturate(mask * strength));
            }
#else   // ---- Basic quality: single desynced held-line smear ----
            float env = saturate(1.0 - f / 0.35);
            env *= env;

            float yc      = (slot + hash21(float2(slot, k + 5.0))) / slots;
            float vheight = (3.0 + 8.0 * hash21(float2(slot, k + 9.0))) * px.y;
            float vmask   = smoothstep(vheight, 0.0, abs(texcoord.y - yc));

            float sx    = hash21(float2(slot, k + 7.0));
            float len   = 0.10 + 0.45 * hash21(float2(slot, k + 13.0));
            float xrel  = texcoord.x - sx;
            float hmask = smoothstep(0.0, 0.06, xrel) * smoothstep(0.0, 0.06, len - xrel);

            float mask = vmask * hmask * env;
            if (mask > 0.001)
            {
                // Held/smeared content from the line just above, pulled left (5-tap).
                float  srcY   = yc - vheight - px.y;
                float  cx     = uv.x - 3.0 * px.x;
                float  spread = 3.0 * px.x;
                float3 s = 0.15 * DropTap(float2(cx - 2.0 * spread, srcY))
                         + 0.20 * DropTap(float2(cx -       spread, srcY))
                         + 0.30 * DropTap(float2(cx,               srcY))
                         + 0.20 * DropTap(float2(cx +       spread, srcY))
                         + 0.15 * DropTap(float2(cx + 2.0 * spread, srcY));

                // Desaturate, push toward bright (or occasionally a dark hit), speckle.
                float sl = dot(s, float3(0.299, 0.587, 0.114));
                s = lerp(s, float3(sl, sl, sl), 0.45);

                float  polarity = hash21(float2(slot, k + 21.0));
                float3 target   = (polarity < 0.82) ? float3(1.0, 1.0, 1.0)
                                                    : float3(0.0, 0.0, 0.0);
                float  lift     = lerp(0.30, 0.12, DropoutSoftness);
                s = lerp(s, target, lift);

                float2 np  = texcoord * ReShade::ScreenSize + k * 3.1;
                float3 spk = float3(hash21(np + 1.0), hash21(np + 2.0), hash21(np + 3.0)) - 0.5;
                s += spk * 0.06;

                float strength = (0.55 + 0.35 * hash21(float2(slot, k + 3.0)))
                               * lerp(0.9, 0.55, DropoutSoftness);
                col = lerp(col, s, saturate(mask * strength));
            }
#endif
        }
    }

    col = lerp(orig, col, EffectStrength);
    return saturate(col);
}

technique VHS_Lite <
    ui_tooltip = "Lightweight VHS tape degradation driven by one Tape Wear lever.\nRun AFTER NTSC_Blur, BEFORE your CRT shader.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_VHS;
    }
}
