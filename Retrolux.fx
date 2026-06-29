/*=============================================================================

    RetroLux  -  Intelligent bloom / screen-space irradiance for retro,
                 baked-lighting games (THPS3, CMR2, GTA3, ...).

    NOT old-school bloom. Late-era games of this period shipped a cheap, mushy
    Gaussian "bloom" that smears light across every silhouette and softens the
    whole frame. RetroLux instead approximates indirect bounce / irradiance
    (fake global illumination) and keeps it DEFINED:

      * Depth-aware (bilateral) blur. The bounce light is spread only across
        surfaces at similar depth, so it stops hard at silhouette edges instead
        of haloing over them. This is what makes it read as a real bounce that
        hugs geometry rather than a soft glow. (Edge Stop control.)
      * Two scales - a tight near bounce (contact color bleed in corners) and a
        broad room-scale ambient - recombined with an unsharp term so the
        result has local-contrast structure, not flat wash. (Bounce Sharpness.)
      * Purely ADDITIVE. No darkening / occlusion term at all: that is MXAO /
        GloomAO's job, and doubling it up only produces grime. RetroLux only
        ever adds light.
      * No per-pixel ray noise and no reprojection, so it is temporally stable
        WITHOUT ghosting under fast skating / racing motion.
      * GloomAO-style Depth Setup group + debug views to align the mask to odd
        depth buffers (the dgVoodoo2 -> D3D11 4:3-internal case).

    Dry/Wet mix blends the whole effect back toward the untouched frame as the
    final step.

    Chain placement: run this BEFORE the presentation chain, i.e.
        RetroLux -> NTSC_Blur -> CRT / CRT_Shadow -> CRT_Glass_Effects

=============================================================================*/

#include "ReShade.fxh"

//=============================================================================
// UI
//=============================================================================

uniform float Intensity <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "GI Intensity"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Strength of the added indirect bounce light.";
> = 0.50;

uniform float BleedRadius <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Near Bleed Radius"; ui_min = 0.5; ui_max = 4.0; ui_step = 0.01;
    ui_tooltip = "Spread of the tight, close-range contact color bleed.";
> = 1.50;

uniform float WideBleed <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Wide Bleed Radius"; ui_min = 1.0; ui_max = 6.0; ui_step = 0.01;
    ui_tooltip = "Spread of the broad, room-scale ambient bounce.";
> = 3.50;

uniform float NearWeight <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Near Weight"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.60;

uniform float WideWeight <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Wide Weight"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
> = 0.40;

uniform float GISaturation <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "GI Saturation"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Boost the chroma of the bounce so color bleed reads on a CRT.";
> = 1.20;

uniform float AlbedoResponse <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Albedo Response"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "How much the receiving surface's own color tints / absorbs\n"
                 "the incoming bounce (0 = uniform add, 1 = full radiosity tint).";
> = 0.50;

uniform float EmitThreshold <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Emit Threshold"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Only surfaces brighter than this contribute bounce light.\n"
                 "Raise it to make the bloom come from defined light sources\n"
                 "(true bloom) rather than the whole scene. 0 = everything emits.";
> = 0.00;

uniform float HighlightRolloff <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Highlight Rolloff (soft light)"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Attenuates the additive bounce in already-bright areas so the\n"
                 "GI reads as soft light that can't blow out highlights.\n"
                 "1 = full soft (screen-like), 0 = plain linear add.";
> = 0.70;

uniform float DitherAmount <
    ui_type = "slider"; ui_category = "Global Illumination";
    ui_label = "Dither"; ui_min = 0.0; ui_max = 2.0; ui_step = 0.01;
    ui_tooltip = "Breaks up banding in the smooth GI gradient on low-bit output.";
> = 0.50;

// ---- Definition: what keeps this from looking like soft old-school bloom ----

uniform float EdgeStop <
    ui_type = "slider"; ui_category = "Definition";
    ui_label = "Edge Stop"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "How hard the bounce halts at depth discontinuities.\n"
                 "0 = plain Gaussian (soft, leaks over silhouettes - the old\n"
                 "    bloom look).\n"
                 "1 = tight bilateral: the bounce hugs each surface and stops\n"
                 "    dead at edges, reading as real bounced light.";
> = 0.65;

uniform float BounceSharpness <
    ui_type = "slider"; ui_category = "Definition";
    ui_label = "Bounce Sharpness"; ui_min = 0.0; ui_max = 1.5; ui_step = 0.01;
    ui_tooltip = "Adds the high-frequency difference between the near and wide\n"
                 "bounce back in (unsharp), giving the irradiance local-contrast\n"
                 "structure instead of a flat wash. 0 = smooth.";
> = 0.35;

uniform int DepthMode <
    ui_type = "combo"; ui_category = "Depth Setup";
    ui_label = "Depth Mode"; ui_items = "Normal\0Reversed\0";
    ui_tooltip = "Flip if the depth reads inverted (near/far swapped).";
> = 0;

uniform float DepthScaleH <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Depth Scale H"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.001;
    ui_tooltip = "Horizontal scale of the depth sampling, centered.\n"
                 "Use with the Mask / Edges debug view to line depth up\n"
                 "with the visible scene on odd (4:3-internal) buffers.";
> = 1.000;

uniform float DepthScaleV <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Depth Scale V"; ui_min = 0.5; ui_max = 2.0; ui_step = 0.001;
> = 1.000;

uniform float DepthOffsetX <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Depth Offset X"; ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.000;

uniform float DepthOffsetY <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Depth Offset Y"; ui_min = -0.5; ui_max = 0.5; ui_step = 0.001;
> = 0.000;

uniform float SkyThreshold <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Sky Cutoff (far)"; ui_min = 0.50; ui_max = 1.00; ui_step = 0.001;
    ui_tooltip = "Depth beyond this is treated as sky: emits no bounce and\n"
                 "receives no GI.";
> = 0.990;

uniform float NearThreshold <
    ui_type = "slider"; ui_category = "Depth Setup";
    ui_label = "Near Cutoff (particles/HUD)"; ui_min = 0.00; ui_max = 0.20; ui_step = 0.001;
    ui_tooltip = "Depth nearer than this is excluded - keeps smoke/dirt\n"
                 "sprites and HUD out of the GI.";
> = 0.000;

uniform float DryWet <
    ui_type = "slider"; ui_category = "Mix";
    ui_label = "Dry / Wet"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_tooltip = "Blend the whole effect back toward the untouched frame.\n"
                 "0 = dry (original image), 1 = full RetroLux.";
> = 1.00;

uniform int DebugView <
    ui_type = "combo"; ui_category = "Debug";
    ui_label = "Setup / Debug View";
    ui_items = "Off\0Linear Depth\0GI Mask\0GI Only\0Depth Edges\0";
    ui_tooltip = "Mask: green = receives GI, red = sky (excluded),\n"
                 "blue = near/particle (excluded).\n"
                 "Depth Edges: depth silhouettes in red over the scene -\n"
                 "drag Depth Scale/Offset until they hug the skater & level.";
> = 0;

//=============================================================================
// Targets  (quarter-res near pyramid, eighth-res wide pyramid)
//   .rgb = masked emitted / bounced light, .a = linear depth (carried so the
//   separable blur can weight taps bilaterally by depth similarity).
//=============================================================================

#define RLGI_DIV_A 4
#define RLGI_DIV_B 8

texture RLGI_ExtractTex { Width = BUFFER_WIDTH / RLGI_DIV_A; Height = BUFFER_HEIGHT / RLGI_DIV_A; Format = RGBA16F; };
sampler RLGI_Extract { Texture = RLGI_ExtractTex; };

texture RLGI_TmpATex   { Width = BUFFER_WIDTH / RLGI_DIV_A; Height = BUFFER_HEIGHT / RLGI_DIV_A; Format = RGBA16F; };
sampler RLGI_TmpA  { Texture = RLGI_TmpATex; };

texture RLGI_GIATex    { Width = BUFFER_WIDTH / RLGI_DIV_A; Height = BUFFER_HEIGHT / RLGI_DIV_A; Format = RGBA16F; };
sampler RLGI_GIA   { Texture = RLGI_GIATex; };

texture RLGI_TmpBTex   { Width = BUFFER_WIDTH / RLGI_DIV_B; Height = BUFFER_HEIGHT / RLGI_DIV_B; Format = RGBA16F; };
sampler RLGI_TmpB  { Texture = RLGI_TmpBTex; };

texture RLGI_GIBTex    { Width = BUFFER_WIDTH / RLGI_DIV_B; Height = BUFFER_HEIGHT / RLGI_DIV_B; Format = RGBA16F; };
sampler RLGI_GIB   { Texture = RLGI_GIBTex; };

//=============================================================================
// Helpers
//=============================================================================

static const float3 LUMA = float3(0.299, 0.587, 0.114);

// Linearized depth with the GloomAO-style centered scale/offset transform
// and a runtime normal/reversed flip, so the mask can be aligned to odd buffers.
float RLGI_GetDepth(float2 tc)
{
    float2 scale = float2(DepthScaleH, DepthScaleV);
    float2 mid   = (scale - 1.0) * 0.5;            // keep the scale centered
    tc = tc * scale - mid + float2(DepthOffsetX, DepthOffsetY);

    float d = ReShade::GetLinearizedDepth(saturate(tc));
    if (DepthMode == 1) d = 1.0 - d;
    return d;
}

// 1 where GI applies, fading to 0 for sky (far) and near particles/HUD.
float RLGI_Mask(float d)
{
    float skyM  = 1.0 - smoothstep(SkyThreshold - 0.02, SkyThreshold, d);
    float nearM = smoothstep(NearThreshold, NearThreshold + 0.005, d);
    return saturate(skyM * nearM);
}

// Maps the Edge Stop slider to a depth sigma. Big sigma -> tap depth is almost
// ignored (plain Gaussian); small sigma -> bounce stops dead at depth edges.
float RLGI_DepthSigma()
{
    return lerp(0.50, 0.012, EdgeStop);
}

// Separable bilateral 7-tap Gaussian over a target whose .a holds linear depth.
// 'step' already encodes direction * texel * radius. Taps that differ in depth
// from the center are down-weighted, so light never bleeds across silhouettes.
// Returns rgb = blurred bounce, a = center depth (carried to the next pass).
float4 RLGI_BilatGauss(sampler s, float2 uv, float2 step)
{
    const float w0 = 0.227027, w1 = 0.194595, w2 = 0.121622, w3 = 0.054054;

    float4 c0 = tex2D(s, uv);
    float  dC = c0.a;
    float  sig = RLGI_DepthSigma();
    float  inv = 1.0 / (2.0 * sig * sig);

    float3 sum  = c0.rgb * w0;
    float  wsum = w0;

    [unroll]
    for (int i = 1; i <= 3; i++)
    {
        float  sw = (i == 1) ? w1 : (i == 2) ? w2 : w3;
        float2 o  = step * i;

        float4 tp = tex2D(s, uv + o);
        float4 tn = tex2D(s, uv - o);

        float wp = sw * exp(-(tp.a - dC) * (tp.a - dC) * inv);
        float wn = sw * exp(-(tn.a - dC) * (tn.a - dC) * inv);

        sum  += tp.rgb * wp + tn.rgb * wn;
        wsum += wp + wn;
    }

    return float4(sum / max(wsum, 1e-5), dC);
}

//=============================================================================
// Passes
//=============================================================================

// Pass 0 - extract masked, thresholded light + depth into the quarter-res buffer.
float4 PS_Extract(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 c = tex2D(ReShade::BackBuffer, uv).rgb;
    float  d = RLGI_GetDepth(uv);
    float  mask = RLGI_Mask(d);

    float emitW = 1.0;
    if (EmitThreshold > 0.0)
    {
        float luma = dot(c, LUMA);
        emitW = smoothstep(EmitThreshold, min(1.0, EmitThreshold + 0.25), luma);
    }

    // rgb = emitted light (mask zeroes sky/near so they never leak), a = depth.
    return float4(c * emitW * mask, d);
}

float4 PS_BlurAH(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 step = float2(BUFFER_RCP_WIDTH, 0.0) * RLGI_DIV_A * BleedRadius;
    return RLGI_BilatGauss(RLGI_Extract, uv, step);
}

float4 PS_BlurAV(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 step = float2(0.0, BUFFER_RCP_HEIGHT) * RLGI_DIV_A * BleedRadius;
    return RLGI_BilatGauss(RLGI_TmpA, uv, step);
}

// Wide level: source is the quarter-res extract, target is eighth-res, with a
// larger step -> a broad, soft room-scale irradiance field (still bilateral).
float4 PS_BlurBH(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 step = float2(BUFFER_RCP_WIDTH, 0.0) * RLGI_DIV_B * WideBleed;
    return RLGI_BilatGauss(RLGI_Extract, uv, step);
}

float4 PS_BlurBV(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float2 step = float2(0.0, BUFFER_RCP_HEIGHT) * RLGI_DIV_B * WideBleed;
    return RLGI_BilatGauss(RLGI_TmpB, uv, step);
}

float4 PS_Composite(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 scene = tex2D(ReShade::BackBuffer, uv).rgb;
    float  d     = RLGI_GetDepth(uv);
    float  mask  = RLGI_Mask(d);

    float3 giA = tex2D(RLGI_GIA, uv).rgb;   // tight near bounce
    float3 giB = tex2D(RLGI_GIB, uv).rgb;   // broad room bounce

    // combine the two scales, then add the near<->wide difference back in
    // (unsharp) so the bounce keeps local-contrast structure instead of washing
    // out - this is the "defined", not "soft", half of the look.
    float3 gi = giA * NearWeight + giB * WideWeight;
    gi = max(0.0.xxx, gi + (giA - giB) * BounceSharpness);

    // chroma boost on the bounce term
    float gl = dot(gi, LUMA);
    gi = lerp(gl.xxx, gi, GISaturation);

    // receiving surface tints / absorbs the bounce (radiosity behaviour)
    gi *= lerp(1.0.xxx, scene, AlbedoResponse);

    // ordered-ish dither to fight banding in the smooth gradient
    if (DitherAmount > 0.0)
    {
        float dn = frac(sin(dot(vpos.xy, float2(12.9898, 78.233))) * 43758.5453);
        gi += (dn - 0.5) * (DitherAmount / 255.0);
    }

    // soft additive light: roll the bounce off where the scene is already bright
    // so it can't clip - gentler, more "ambient light" than "paint".
    // Purely additive: no darkening term (that is MXAO/GloomAO's job).
    float3 add    = gi * Intensity * mask;
    float3 result = scene + add * (1.0 - saturate(scene) * HighlightRolloff);

    // ---- Setup / debug overlays (unaffected by Dry/Wet) ----
    if (DebugView == 1)            // linear depth
        return float4(d.xxx, 1.0);
    if (DebugView == 2)            // mask: green=GI, red=sky, blue=near
    {
        float skyM  = step(SkyThreshold, d);
        float nearM = step(d, NearThreshold);
        float3 m = float3(skyM, mask, nearM);
        return float4(lerp(scene * 0.25, m, 0.85), 1.0);
    }
    if (DebugView == 3)            // GI contribution only
        return float4(gi * Intensity * mask, 1.0);
    if (DebugView == 4)            // depth silhouettes over scene
    {
        float dx = abs(d - RLGI_GetDepth(uv + float2(BUFFER_RCP_WIDTH, 0.0)));
        float dy = abs(d - RLGI_GetDepth(uv + float2(0.0, BUFFER_RCP_HEIGHT)));
        float e = saturate((dx + dy) * 60.0);
        return float4(lerp(scene, float3(1.0, 0.0, 0.0), e), 1.0);
    }

    // Dry/Wet: blend the finished effect back toward the untouched frame last.
    result = lerp(scene, saturate(result), DryWet);
    return float4(result, 1.0);
}

//=============================================================================
// Technique
//=============================================================================

technique RetroLux <
    ui_tooltip = "RetroLux - intelligent bloom / screen-space irradiance for\n"
                 "retro, baked-lighting games. Depth-aware (bilateral) indirect\n"
                 "bounce that hugs geometry and stays defined instead of soft;\n"
                 "purely additive (no darkening - leave that to MXAO/GloomAO).\n"
                 "Place before the NTSC/CRT presentation chain.";
>
{
    pass Extract { VertexShader = PostProcessVS; PixelShader = PS_Extract; RenderTarget = RLGI_ExtractTex; }
    pass BlurAH  { VertexShader = PostProcessVS; PixelShader = PS_BlurAH;  RenderTarget = RLGI_TmpATex;    }
    pass BlurAV  { VertexShader = PostProcessVS; PixelShader = PS_BlurAV;  RenderTarget = RLGI_GIATex;     }
    pass BlurBH  { VertexShader = PostProcessVS; PixelShader = PS_BlurBH;  RenderTarget = RLGI_TmpBTex;    }
    pass BlurBV  { VertexShader = PostProcessVS; PixelShader = PS_BlurBV;  RenderTarget = RLGI_GIBTex;     }
    pass Composite { VertexShader = PostProcessVS; PixelShader = PS_Composite; }
}
