//================================================================
//  TAA_Hybrid_Perceptual.fx
//  Fast / action build.
//  Bias: anti-GHOSTING first, flicker second (the quality build is
//  the inverse). At action pace trails and smear are what the eye
//  locks onto and shimmer largely hides in the motion, so defaults
//  favor fast, clean, responsive motion over converged stillness.
//  Defaults assume SMAA (or similar spatial AA) runs BEFORE this
//  effect: it carries edge AA during motion, pre-softens crawl, and
//  its per-frame edge-weight wobble is absorbed by the noise floor.
//  Running without SMAA? Drop Motion Noise Floor ~0.01 and tighten
//  Luma Clamp back toward 0.75.
//  Color + Depth history rejection, perceptually weighted:
//    - clip-to-AABB history rectification (Playdead): pulls stale
//      history toward the neighborhood box center -> fewer clamp
//      artifacts than a per-channel clamp.
//    - motion-adaptive clamp: the box tightens only where motion is
//      detected, so moving history clips hard (kills trails) while
//      static regions stay loose (shimmer + accumulation survive).
//    - capped convergent accumulation: a low-N running average with a
//      hard reset on rejection -> a little static AA, still responsive.
//  Luma carries crawl: police luma tightly, let chroma persist;
//  blend in tonemapped space to kill bright-edge flicker.
//  Clean-room. Refs (public): Karis SIGGRAPH 2014 (luma/tonemap
//  anti-flicker); Salvi variance clamping; Playdead INSIDE (clip-to-AABB).
//================================================================
#include "ReShade.fxh"

// Compile-time depth toggle (a real preprocessor define, NOT a uniform, so
// the compiler can dead-strip the whole path). Set TAA_USE_DEPTH=0 in
// ReShade's "Preprocessor definitions" box for this effect when the game has
// no working depth buffer: drops both depth fetches in Resolve,
// the edge-mask / luma-range work that only feeds depth relief, the Save-pass
// depth write, and the texPrevDepth render target + its VRAM. The runtime
// "Depth Confidence" slider still exists when this is 1, for soft disabling.
#ifndef TAA_USE_DEPTH
#define TAA_USE_DEPTH 1
#endif

// Perf knobs, same idea as TAA_USE_DEPTH (compile-time -> dead paths strip).
// The shader is bandwidth-bound; these trade minor features for real ms:
//   TAA_CHROMA_MOTION 0 -> motion detection goes luma-only: texPrevRaw shrinks
//     RGBA8 -> R8 (4x less traffic on every prevRaw tap + the Save write) and
//     the Chroma Motion Weight slider disappears. Luma carries nearly all
//     visible motion; this is the cheapest quality trade in the file.
//   TAA_DEBUG 0 -> strips the debug render target, its per-frame write, and
//     the Debug combo. Set 0 once tuning is done.
//   TAA_FLICKER 0 -> strips the flicker discriminator (the "Flicker" category:
//     frame-to-frame luma diffs that alternate sign are shimmer, not motion,
//     so they're exempted from rejection and allowed to accumulate away) and
//     its two R8 targets.
//   TAA_COMPACT_HISTORY 1 (default) -> history + resolve stored RGB10A2 with
//     the N counter in a separate R8 instead of RGBA16F: halves the traffic
//     on the two fattest surfaces (the single biggest cost in the file). A
//     half-LSB temporal dither keeps the 10-bit running average converging.
//     Set 0 to restore full 16F storage.
//   TAA_WIDE_BOX 1 -> full 3x3 (9-tap) variance box like the quality build.
//     Default 0: 5-tap cross, the standard fast-path pattern - 4 fewer
//     backbuffer taps for a marginally noisier clamp box.
#ifndef TAA_CHROMA_MOTION
#define TAA_CHROMA_MOTION 1
#endif
#ifndef TAA_DEBUG
#define TAA_DEBUG 1
#endif
#ifndef TAA_FLICKER
#define TAA_FLICKER 1
#endif
#ifndef TAA_COMPACT_HISTORY
#define TAA_COMPACT_HISTORY 1
#endif
#ifndef TAA_WIDE_BOX
#define TAA_WIDE_BOX 0
#endif
#if TAA_WIDE_BOX
#define TAA_TAPS 9
#else
#define TAA_TAPS 5
#endif

uniform float Persistence <
    ui_type="slider"; ui_min=0.0; ui_max=0.5; ui_label="History Floor";
    ui_tooltip="Min current-frame weight (floor on the 1/N average). Lower = deeper accumulation /\nmore ghost risk. Runs HIGH here (anti-ghost bias): shallow memory = short trails. ~0.06-0.10.";
    ui_category="Blend";
> = 0.08;

uniform float AccumCap <
    ui_type="slider"; ui_min=2.0; ui_max=32.0; ui_label="Accum Cap (N max)";
    ui_tooltip="Max frames the running average converges over. Kept LOW here so the fast build\nstays responsive; collapses to 1 instantly on rejection. ~6-10.";
    ui_category="Blend";
> = 8.0;

uniform float GammaLuma <
    ui_type="slider"; ui_min=0.25; ui_max=3.0; ui_label="Luma Clamp Tightness";
    ui_tooltip="Std-dev mult for the LUMA box. LOW = tight = kills shimmer. SMAA pre-softens crawl,\nso this runs a touch looser (better edge accumulation); tighten toward 0.75 if\nrunning without SMAA. ~0.7-1.0.";
    ui_category="Perceptual Clamp";
> = 0.85;

uniform float GammaChroma <
    ui_type="slider"; ui_min=0.5; ui_max=6.0; ui_label="Chroma Clamp Looseness";
    ui_tooltip="Std-dev mult for CHROMA. HIGH = loose = color history persists (chroma ghosting is\nperceptually cheap, buys cleaner accumulation). ~2-3.";
    ui_category="Perceptual Clamp";
> = 2.5;

uniform float ClampFeedback <
    ui_type="slider"; ui_min=0.0; ui_max=8.0; ui_label="Clamp-Distance Reject";
    ui_tooltip="History that sat far OUTSIDE the box raises rejection. Cuts ghosting without globally\ntightening the box. Runs HIGH here (anti-ghost bias): stale history dies fast. ~3-4.";
    ui_category="Perceptual Clamp";
> = 3.5;

uniform float MotionClampTighten <
    ui_type="slider"; ui_min=0.2; ui_max=1.0; ui_label="Motion Clamp Tighten";
    ui_tooltip="Shrinks the clamp box where motion is detected -> clips moving history harder ->\nkills ghost trails, while static regions keep the loose box (shimmer stays controlled).\nLower = more aggressive. Runs aggressive here (anti-ghost bias). ~0.35-0.5.";
    ui_category="Perceptual Clamp";
> = 0.4;

uniform float ColorFloor <
    ui_type="slider"; ui_min=0.0; ui_max=0.2; ui_label="Motion Noise Floor";
    ui_tooltip="Luma change below this = texture noise, not motion. Sized to absorb SMAA's\nper-frame edge-weight wobble (drop ~0.01 without SMAA). Low = sensitive gate =\nleast ghosting; raise on heavy film grain / dithering. ~0.03-0.06.";
    ui_category="Color Reject";
> = 0.04;

uniform float ColorGain <
    ui_type="slider"; ui_min=1.0; ui_max=16.0; ui_label="Motion Reject Gain";
    ui_tooltip="How fast rejection ramps to full above the noise floor. Runs HIGH here (anti-ghost\nbias): motion snaps to the crisp current frame instead of half-blending. ~6-10.";
    ui_category="Color Reject";
> = 8.0;

#if TAA_CHROMA_MOTION
uniform float ChromaWeight <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Chroma Motion Weight";
    ui_tooltip="How much chroma motion counts vs luma. Keep low; luma carries visible motion.";
    ui_category="Color Reject";
> = 0.25;
#endif

uniform bool MotionDilate <
    ui_label="Motion Dilation (cross)";
    ui_tooltip="Takes the max luma frame-difference over a 5-tap cross instead of a single\ncenter tap. Helps ONLY noise-dominated content (film grain, dither): coherent\nmotion regions behave identically, but it also widens the reject band around\nshimmering thin edges, blocking the accumulation that would smooth them.\nCheck with Debug > Luma Motion: if you see snow resolving into shapes, keep\nit on; if you see edges thickening, leave it off. Costs 4 extra history taps.";
    ui_category="Color Reject";
> = false;

#if TAA_FLICKER
uniform float FlickerSuppress <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Flicker Suppress";
    ui_tooltip="How strongly detected shimmer is exempted from motion rejection, letting\naccumulation converge on sizzling thin edges (rails, wires, fences). Shimmer =\nframe-to-frame luma diff that alternates sign; real motion is sustained and\ndoesn't. Genuinely strobing content may soften slightly - the tight luma\nclamp bounds it. 0 = off. Runs MODERATE here (anti-ghost bias): a misread\nexemption is a small ghost risk, so flicker takes second place. ~0.4-0.7.";
    ui_category="Flicker";
> = 0.6;

uniform float FlickerSense <
    ui_type="slider"; ui_min=25.0; ui_max=800.0; ui_label="Flicker Sensitivity";
    ui_tooltip="Gain on the alternation detector (product of successive signed luma diffs).\nHigher = smaller oscillations count as shimmer. Check with Debug > Flicker\nMask: static sizzling edges should light up, moving objects should not.\nRuns lower than the quality build (anti-ghost bias: only clear sizzle earns\nan exemption) but raised for SMAA: pre-softened oscillations are smaller\nand need more gain to register. ~150-300.";
    ui_category="Flicker";
> = 200.0;
#endif

#if TAA_USE_DEPTH
uniform float DepthConfidence <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Depth Confidence";
    ui_tooltip="Master weight for depth. 0 = pure color mode (set this if depth is broken).";
    ui_category="Depth";
> = 0.6;

uniform float DepthGain <
    ui_type="slider"; ui_min=1.0; ui_max=512.0; ui_label="Depth Reject Gain";
    ui_category="Depth";
> = 128.0;

uniform float DepthEdgeRelief <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Depth Edge Relief";
    ui_tooltip="Suppresses depth rejection on high-contrast edges so it stops eating the accumulation\nthat antialiases thin edges. 1 = full relief on edges.";
    ui_category="Depth";
> = 0.7;

uniform float EdgeScale <
    ui_type="slider"; ui_min=1.0; ui_max=12.0; ui_label="Edge Sensitivity";
    ui_tooltip="How readily local luma contrast counts as an edge for depth relief. Runs a step\nhigher assuming SMAA: softened edges produce smaller luma ranges.";
    ui_category="Depth";
> = 5.0;
#endif // TAA_USE_DEPTH

uniform int CombineMode <
    ui_type="combo"; ui_items="Union (max)\0Sum\0Depth-gated color\0";
    ui_label="Combine"; ui_category="Combine";
> = 0;

#if TAA_DEBUG
uniform int Debug <
    ui_type="combo"; ui_items="Off\0Reject\0Luma Motion\0Depth Signal\0Edge Mask\0Clamp Distance\0Accum Count\0Flicker Mask\0";
    ui_label="Debug"; ui_category="Debug";
> = 0;
#endif

#if TAA_COMPACT_HISTORY
uniform uint FrameCount < source="framecount"; >;
// RGB10A2 + separate R8 N counter: half the bytes of RGBA16F on the surfaces
// touched most. Safe here because the fast build's accumulation is shallow
// (N<=32, floor 0.07): per-frame increments stay well above one 10-bit step,
// and the dithered write (see PS_Resolve) carries sub-LSB information.
texture texResolve  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGB10A2; };
texture texResolveN { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };
sampler sResolveN   { Texture=texResolveN; };
texture texPrevColor{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGB10A2; };
texture texPrevN    { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };
sampler sPrevN      { Texture=texPrevN; };
#else
// RGBA16F so the running average + N counter (in alpha) don't quantize
texture texResolve  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA16F; };
texture texPrevColor{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA16F; };
#endif
sampler sResolve    { Texture=texResolve; };
sampler sPrevColor  { Texture=texPrevColor; };
#if TAA_CHROMA_MOTION
texture texPrevRaw  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA8; };
#else
texture texPrevRaw  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };   // luma only
#endif
sampler sPrevRaw    { Texture=texPrevRaw; };
#if TAA_DEBUG
// debug signal gets its own target: Resolve always writes the true history,
// so enabling a debug view no longer feeds the visualization back into itself
texture texDebug    { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };
sampler sDebug      { Texture=texDebug; };
#endif
#if TAA_FLICKER
// signed luma diff double-buffer for the alternation test (0.5 = no change)
texture texCurDiff  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };
sampler sCurDiff    { Texture=texCurDiff; };
texture texPrevDiff { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8; };
sampler sPrevDiff   { Texture=texPrevDiff; };
#endif
#if TAA_USE_DEPTH
// R16 UNORM, deliberately not float: linearized depth is 0..1, so uniform
// 1/65535 steps beat R16F's ~5e-4 far-field quantization 30x over, at half
// R32F's bandwidth. Even DepthGain 512 x one step stays under 1% false reject.
texture texPrevDepth{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R16; };
sampler sPrevDepth  { Texture=texPrevDepth; };
#endif

#define PIX float2(BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT)

float  luma(float3 c){ return dot(c, float3(0.299,0.587,0.114)); }
// exact BT.601 pair: fromYUV(toYUV(c)) == c to float precision. History
// round-trips these every frame, so truncated constants drift the average.
float3 toYUV(float3 c){ return float3(
    luma(c),
    dot(c,float3(-0.168736,-0.331264, 0.500000)),
    dot(c,float3( 0.500000,-0.418688,-0.081312))); }
float3 fromYUV(float3 y){ return float3(
    dot(y,float3(1.0, 0.000000, 1.402000)),
    dot(y,float3(1.0,-0.344136,-0.714136)),
    dot(y,float3(1.0, 1.772000, 0.000000))); }
// luma-weighted reinhard tonemap -> flicker-free blend space
float3 tm (float3 c){ return c * rcp(1.0 + luma(c)); }
float3 itm(float3 c){ return c * rcp(max(1.0 - luma(c), 1e-4)); }

// clip history toward the AABB center, stopping at the box surface
float3 clipToAABB(float3 hist, float3 mn, float3 mx)
{
    float3 center  = 0.5 * (mx + mn);
    float3 extents = 0.5 * (mx - mn) + 1e-5;
    float3 disp    = hist - center;
    float3 ts      = abs(extents / max(abs(disp), 1e-5));
    float  t       = saturate(min(ts.x, min(ts.y, ts.z)));
    return center + disp * t;   // inside box -> t=1 -> unchanged
}

void PS_Resolve(float4 vpos:SV_Position, float2 uv:TEXCOORD,
                out float4 oColor:SV_Target0
#if TAA_COMPACT_HISTORY
              , out float oN:SV_Target1
#endif
#if TAA_DEBUG
#if TAA_COMPACT_HISTORY
              , out float oDebug:SV_Target2
#else
              , out float oDebug:SV_Target1
#endif
#endif
#if TAA_FLICKER
#if TAA_COMPACT_HISTORY && TAA_DEBUG
              , out float oDiff:SV_Target3
#elif TAA_COMPACT_HISTORY || TAA_DEBUG
              , out float oDiff:SV_Target2
#else
              , out float oDiff:SV_Target1
#endif
#endif
                )
{
    float3 cur     = tex2D(ReShade::BackBuffer, uv).rgb;
    float4 histA   = tex2D(sPrevColor, uv);   // .rgb history (.a holds N only when 16F)
    float3 hist    = histA.rgb;

    // signal 1: luma-weighted motion (also drives the clamp tightening).
    // Luma part optionally dilated to the cross max inside the stats loop
    // below, so the tighten signal is spatially coherent, not per-pixel noisy.
    float3 cy = toYUV(cur);
#if TAA_CHROMA_MOTION
    float3 py = toYUV(tex2D(sPrevRaw, uv).rgb);
    float sd        = cy.x - py.x;         // SIGNED: sign feeds the flicker test
    float chromaMot = length(cy.yz - py.yz);
#else
    float sd        = cy.x - tex2D(sPrevRaw, uv).x;        // R8 stores luma
#endif
    float lumaMot   = abs(sd);

    // neighborhood stats in YUV: variance box always; luma range only when
    // depth is compiled in (it exists solely to feed the edge mask for relief)
    static const float2 off[9] = { float2(0,0),
        float2(0,1),float2(0,-1),float2(1,0),float2(-1,0),
        float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1) };
    float3 m1=0, m2=0;
#if TAA_USE_DEPTH
    float yMin=1e9, yMax=-1e9;
#endif
    [unroll] for (int i=0;i<TAA_TAPS;i++){
        float3 s = toYUV(tex2Dlod(ReShade::BackBuffer, float4(uv+off[i]*PIX,0,0)).rgb);
        m1 += s; m2 += s*s;
#if TAA_USE_DEPTH
        yMin = min(yMin, s.x); yMax = max(yMax, s.x);
#endif
        // off[1..4] is the axis cross; diagonals add ~nothing to a max-dilate
        if (MotionDilate && i > 0 && i < 5) {
#if TAA_CHROMA_MOTION
            float pl = luma(tex2Dlod(sPrevRaw, float4(uv+off[i]*PIX,0,0)).rgb);
#else
            float pl = tex2Dlod(sPrevRaw, float4(uv+off[i]*PIX,0,0)).x;
#endif
            lumaMot = max(lumaMot, abs(s.x - pl));
        }
    }
#if TAA_CHROMA_MOTION
    float motion    = lumaMot + ChromaWeight*chromaMot;
#else
    float motion    = lumaMot;
#endif
    float colorDiff = saturate((motion - ColorFloor) * ColorGain);

#if TAA_FLICKER
    // flicker discriminator: successive signed diffs with a negative product
    // are oscillation (aliasing sizzle), not motion -> exempt from rejection
    // so accumulation converges there. Applied before the box tighten too, so
    // shimmering pixels also keep the loose static clamp.
    float sdPrev  = tex2D(sPrevDiff, uv).x * 2.0 - 1.0;
    float flicker = saturate(-sd * sdPrev * FlickerSense);
    colorDiff *= 1.0 - FlickerSuppress * flicker;
#endif

    float3 mean  = m1 / float(TAA_TAPS);
    float3 sigma = sqrt(max(m2/float(TAA_TAPS) - mean*mean, 0.0));
    // tight luma / loose chroma, tightened further where motion is detected
    float3 gamma = float3(GammaLuma, GammaChroma, GammaChroma)
                 * lerp(1.0, MotionClampTighten, colorDiff);
    float3 mn = mean - gamma*sigma;
    float3 mx = mean + gamma*sigma;

    // clip-to-AABB rectification (toward box center)
    float3 hy  = toYUV(hist);
    float3 hyC = clipToAABB(hy, mn, mx);
    float  clampDist   = distance(hy, hyC);          // luma-dominated staleness
    // bypass the YUV round-trip when nothing clipped: converged history stays bit-exact
    float3 histClamped = clampDist > 1e-6 ? fromYUV(hyC) : hist;

#if TAA_USE_DEPTH
    float edge = saturate((yMax - yMin) * EdgeScale);
#endif

    // signal 2: depth velocity, relieved on edges
#if TAA_USE_DEPTH
    float curD  = ReShade::GetLinearizedDepth(uv);
    float prevD = tex2D(sPrevDepth, uv).x;
    float depthVel = saturate(abs(curD - prevD) * DepthGain) * DepthConfidence;
    depthVel *= lerp(1.0, 1.0 - DepthEdgeRelief, edge);
#endif

    // combine + clamp-distance feedback
#if TAA_USE_DEPTH
    float reject;
    if      (CombineMode==0) reject = max(colorDiff, depthVel);
    else if (CombineMode==1) reject = saturate(colorDiff + depthVel);
    else                     reject = saturate(depthVel + colorDiff*(1.0-depthVel));
#else
    float reject = colorDiff;                          // depth stripped: color only
#endif
    reject = max(reject, saturate(clampDist * ClampFeedback));

    // --- capped convergent accumulation (low cap = stays responsive) ---
#if TAA_COMPACT_HISTORY
    float N = max(tex2D(sPrevN, uv).x * 32.0, 1.0);    // R8, scaled to slider max
#else
    float N = max(histA.a, 1.0);                       // frames accumulated so far
#endif
    float convWeight = rcp(N);                         // 1/N running-average weight
    float mixRate = max(convWeight, reject);           // reject overrides convergence
    mixRate = clamp(mixRate, Persistence, 1.0);

    // tonemapped (flicker-free) blend
    float3 outRGB = itm( lerp(tm(histClamped), tm(cur), mixRate) );

    // grow N toward cap, collapse to 1 on rejection (hard reset = low ghost)
    float grown = min(N + 1.0, AccumCap);
    float Nnext = lerp(grown, 1.0, saturate(reject));

#if TAA_DEBUG
    float dbg = 0.0;
    if      (Debug==1) dbg = reject;
    else if (Debug==2) dbg = colorDiff;
#if TAA_USE_DEPTH
    else if (Debug==3) dbg = depthVel;
    else if (Debug==4) dbg = edge;
#endif
    else if (Debug==5) dbg = saturate(clampDist*ClampFeedback);
    else if (Debug==6) dbg = Nnext/AccumCap;
#if TAA_FLICKER
    else if (Debug==7) dbg = flicker;
#endif
    oDebug = dbg;
#endif
#if TAA_COMPACT_HISTORY
    // half-LSB temporal dither (interleaved gradient noise, golden-ratio frame
    // offset): the 10-bit average keeps converging instead of stalling at the
    // quantization step; the noise itself averages out in the history
    float2 dp   = vpos.xy + (FrameCount % 64) * 5.588238;
    float  dith = frac(52.9829189 * frac(dot(dp, float2(0.06711056, 0.00583715)))) - 0.5;
    oColor = float4(outRGB + dith * (1.0/1023.0), 1.0);
    oN     = Nnext * (1.0/32.0);      // scale matches Accum Cap slider max
#else
    oColor = float4(outRGB, Nnext);   // always the true resolve: history stays clean
#endif
#if TAA_FLICKER
    oDiff  = sd * 0.5 + 0.5;          // becomes next frame's alternation reference
#endif
}

void PS_Save(float4 vpos:SV_Position, float2 uv:TEXCOORD,
             out float4 oColor:SV_Target0
#if TAA_COMPACT_HISTORY
           , out float oN:SV_Target1
           , out float4 oRaw:SV_Target2
#else
           , out float4 oRaw:SV_Target1
#endif
#if TAA_USE_DEPTH
#if TAA_COMPACT_HISTORY
           , out float oDepth:SV_Target3
#else
           , out float oDepth:SV_Target2
#endif
#endif
#if TAA_FLICKER
#if TAA_COMPACT_HISTORY && TAA_USE_DEPTH
           , out float oPrevDiff:SV_Target4
#elif TAA_COMPACT_HISTORY || TAA_USE_DEPTH
           , out float oPrevDiff:SV_Target3
#else
           , out float oPrevDiff:SV_Target2
#endif
#endif
             )
{
    oColor = tex2D(sResolve, uv);
#if TAA_COMPACT_HISTORY
    oN     = tex2D(sResolveN, uv).x;
#endif
#if TAA_CHROMA_MOTION
    oRaw   = tex2D(ReShade::BackBuffer, uv);
#else
    oRaw   = luma(tex2D(ReShade::BackBuffer, uv).rgb).xxxx;   // R8 target keeps .r
#endif
#if TAA_USE_DEPTH
    oDepth = ReShade::GetLinearizedDepth(uv);
#endif
#if TAA_FLICKER
    oPrevDiff = tex2D(sCurDiff, uv).x;
#endif
}

float4 PS_Display(float4 vpos:SV_Position, float2 uv:TEXCOORD):SV_Target
{
#if TAA_DEBUG
    if (Debug != 0) return float4(tex2D(sDebug, uv).xxx, 1.0);
#endif
    return float4(tex2D(sResolve, uv).rgb, 1.0);
}

technique TAA_Hybrid_Perceptual
{
    pass Resolve { VertexShader=PostProcessVS; PixelShader=PS_Resolve;
                   RenderTarget0=texResolve;
#if TAA_COMPACT_HISTORY
                   RenderTarget1=texResolveN;
#endif
#if TAA_DEBUG
#if TAA_COMPACT_HISTORY
                   RenderTarget2=texDebug;
#else
                   RenderTarget1=texDebug;
#endif
#endif
#if TAA_FLICKER
#if TAA_COMPACT_HISTORY && TAA_DEBUG
                   RenderTarget3=texCurDiff;
#elif TAA_COMPACT_HISTORY || TAA_DEBUG
                   RenderTarget2=texCurDiff;
#else
                   RenderTarget1=texCurDiff;
#endif
#endif
                 }
    pass Save    { VertexShader=PostProcessVS; PixelShader=PS_Save;
                   RenderTarget0=texPrevColor;
#if TAA_COMPACT_HISTORY
                   RenderTarget1=texPrevN;
                   RenderTarget2=texPrevRaw;
#else
                   RenderTarget1=texPrevRaw;
#endif
#if TAA_USE_DEPTH
#if TAA_COMPACT_HISTORY
                   RenderTarget3=texPrevDepth;
#else
                   RenderTarget2=texPrevDepth;
#endif
#endif
#if TAA_FLICKER
#if TAA_COMPACT_HISTORY && TAA_USE_DEPTH
                   RenderTarget4=texPrevDiff;
#elif TAA_COMPACT_HISTORY || TAA_USE_DEPTH
                   RenderTarget3=texPrevDiff;
#else
                   RenderTarget2=texPrevDiff;
#endif
#endif
                 }
    pass Display { VertexShader=PostProcessVS; PixelShader=PS_Display; }
}