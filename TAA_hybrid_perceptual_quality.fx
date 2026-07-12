//================================================================
//  TAA_Hybrid_Perceptual_Quality.fx
//  For varied or cinematic games: deep-accumulation build.
//  Bias: anti-FLICKER first, ghost-tolerant (the fast build is the
//  inverse). At walking / cruising pace shimmer is what the eye locks
//  onto while brief ghosting hides, so defaults trade reject
//  aggression for history persistence.
//  Defaults assume SMAA (or similar spatial AA) runs BEFORE this
//  effect: it carries edge AA during motion and pre-softens crawl;
//  its per-frame edge-weight wobble is absorbed by the noise floor.
//  Running without SMAA? Drop Motion Noise Floor ~0.01 and tighten
//  Luma Clamp back toward 0.6.
//  Over the perceptual hybrid, adds the two upgrades the slow
//  regime uniquely unlocks:
//    1. Convergent accumulation: 1/N running average (N in history
//       alpha), resets on rejection -> true multi-sample coverage
//       in aligned regions, not a fixed-rate leaky blend.
//    2. Clip-to-AABB history rectification (Karis/Playdead) instead
//       of per-channel clamp -> fewer clamp artifacts.
//  History stored in RGBA16F by default so the running average
//  doesn't quantize (TAA_COMPACT_HISTORY trades that for bandwidth).
//  No profiles: baked for slow, where alignment holds and
//  accumulation actually converges.
//  Catmull-Rom history sampling intentionally omitted: it only
//  helps when reprojecting/resampling at an offset, and there is
//  no reprojection here.
//  Clean-room. Refs (public): Karis SIGGRAPH 2014; Salvi variance
//  clamping; Playdead INSIDE TAA (clip-to-AABB).
//================================================================
#include "ReShade.fxh"

// Compile-time depth toggle (a real preprocessor define, NOT a uniform, so
// the compiler can dead-strip the whole path). Set TAA_USE_DEPTH=0 in
// ReShade's "Preprocessor definitions" box for this effect when the game has
// no working depth buffer: drops both depth fetches in Resolve, the Save-pass
// depth write, and the texPrevDepth render target + its VRAM. The runtime
// "Depth Confidence" slider still exists when this is 1, for soft disabling.
#ifndef TAA_USE_DEPTH
#define TAA_USE_DEPTH 1
#endif

// Perf knobs (compile-time -> dead paths strip). DEFAULTS PRESERVE FULL
// QUALITY - this build's purpose is absolute quality, so unlike the fast
// build every trade is opt-in. Flip only if you need the ms:
//   TAA_FLICKER 0 -> strips the flicker discriminator (the "Flicker"
//     category: frame-to-frame luma diffs that alternate sign are shimmer,
//     not motion, so they're exempted from rejection and allowed to
//     accumulate away) and its two R8 targets. This build's bias leans on
//     it - strip only as a last resort.
//   TAA_DEBUG 0 -> strips the debug render target, its per-frame write, and
//     the Debug combo. Zero visual difference; set 0 once tuning is done.
//   TAA_CHROMA_MOTION 0 -> motion detection goes luma-only: texPrevRaw
//     shrinks RGBA8 -> R8. Cheapest trade; luma carries nearly all motion.
//   TAA_COMPACT_HISTORY 1 -> RGB10A2 history + R8 N counter instead of
//     RGBA16F (the fast build's default; halves the fattest traffic). Deep
//     accumulation at a low History Floor can show faint banding in slow
//     dark gradients even with the dithered write - which is why it is
//     OFF here by default.
//   TAA_WIDE_BOX 0 -> 5-tap cross variance box instead of the full 3x3;
//     4 fewer backbuffer taps, marginally noisier clamp box.
#ifndef TAA_FLICKER
#define TAA_FLICKER 1
#endif
#ifndef TAA_DEBUG
#define TAA_DEBUG 1
#endif
#ifndef TAA_CHROMA_MOTION
#define TAA_CHROMA_MOTION 1
#endif
#ifndef TAA_COMPACT_HISTORY
#define TAA_COMPACT_HISTORY 0
#endif
#ifndef TAA_WIDE_BOX
#define TAA_WIDE_BOX 1
#endif
#if TAA_WIDE_BOX
#define TAA_TAPS 9
#else
#define TAA_TAPS 5
#endif

uniform float Persistence <
    ui_type="slider"; ui_min=0.0; ui_max=0.2; ui_label="History Floor";
    ui_tooltip="Absolute min current-frame weight (hard cap on memory). Keep low for deep\naccumulation - this build's anti-flicker bias wants long memory. Effective\nconvergence depth = min(Accum Cap, 1/this). ~0.02-0.04.";
    ui_category="Accumulation";
> = 0.025;

uniform float AccumCap <
    ui_type="slider"; ui_min=2.0; ui_max=64.0; ui_label="Accum Cap (N max)";
    ui_tooltip="Max frames the running average converges over. Higher = smoother / slower to\nadapt. Pair with a low History Floor. ~16-32.";
    ui_category="Accumulation";
> = 32.0;

uniform float GammaLuma <
    ui_type="slider"; ui_min=0.25; ui_max=3.0; ui_label="Luma Clamp Tightness";
    ui_tooltip="Std-dev mult for LUMA box. LOW = tight = kills shimmer. SMAA pre-softens crawl, so\nthis runs a touch looser than a standalone tune (better edge accumulation);\ntighten toward 0.6 if running without SMAA. ~0.6-0.8.";
    ui_category="Perceptual Clamp";
> = 0.7;

uniform float GammaChroma <
    ui_type="slider"; ui_min=0.5; ui_max=6.0; ui_label="Chroma Clamp Looseness";
    ui_tooltip="Std-dev mult for CHROMA. HIGH = loose = color history persists (cheap perceptually,\nbuys cleaner accumulation). ~2-3.";
    ui_category="Perceptual Clamp";
> = 2.5;

uniform float ClampFeedback <
    ui_type="slider"; ui_min=0.0; ui_max=8.0; ui_label="Clamp-Distance Reject";
    ui_tooltip="History clipped far to reach the box was stale -> raise rejection. Cuts ghosting\nwithout globally tightening. Runs LOW here: this build tolerates brief ghosting\nto keep flicker-killing accumulation alive. ~1.5-2.5.";
    ui_category="Perceptual Clamp";
> = 2.0;

uniform float ColorFloor <
    ui_type="slider"; ui_min=0.0; ui_max=0.2; ui_label="Motion Noise Floor";
    ui_tooltip="Luma change below this = texture noise / shimmer, not motion. Runs HIGH here:\nsub-floor crawl accumulates away (anti-flicker), the luma box bounds any ghost\nthat sneaks under, and SMAA's per-frame edge-weight wobble stays sub-floor\n(drop ~0.01 without SMAA). ~0.05-0.08.";
    ui_category="Color Reject";
> = 0.06;

uniform float ColorGain <
    ui_type="slider"; ui_min=1.0; ui_max=16.0; ui_label="Motion Reject Gain";
    ui_category="Color Reject";
> = 6.0;

#if TAA_CHROMA_MOTION
uniform float ChromaWeight <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Chroma Motion Weight";
    ui_tooltip="How much chroma motion counts vs luma. Keep low.";
    ui_category="Color Reject";
> = 0.25;
#endif

uniform float RejectSoften <
    ui_type="slider"; ui_min=0.3; ui_max=1.0; ui_label="Reject Soften";
    ui_tooltip="Global scale on combined reject. <1 lets aligned history survive longer. Runs LOW\nhere (ghost-tolerant bias): flicker is obvious at this pace, brief ghosting isn't. ~0.5-0.7.";
    ui_category="Color Reject";
> = 0.6;

#if TAA_FLICKER
uniform float FlickerSuppress <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Flicker Suppress";
    ui_tooltip="How strongly detected shimmer is exempted from motion rejection, letting\naccumulation converge on sizzling thin edges (rails, wires, fences). Shimmer =\nframe-to-frame luma diff that alternates sign; real motion is sustained and\ndoesn't. Genuinely strobing content may soften slightly - the tight luma\nclamp bounds it. 0 = off. This build's bias: run HIGH. ~0.7-0.9.";
    ui_category="Flicker";
> = 0.85;

uniform float FlickerSense <
    ui_type="slider"; ui_min=25.0; ui_max=800.0; ui_label="Flicker Sensitivity";
    ui_tooltip="Gain on the alternation detector (product of successive signed luma diffs).\nHigher = smaller oscillations count as shimmer. Check with Debug > Flicker\nMask: static sizzling edges should light up, moving objects should not.\nRuns higher than the fast build (anti-flicker bias), raised further for SMAA:\npre-softened oscillations are smaller and need more gain to register. ~250-400.";
    ui_category="Flicker";
> = 300.0;
#endif

#if TAA_USE_DEPTH
uniform float DepthConfidence <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Depth Confidence";
    ui_tooltip="Master weight for depth. 0 = pure color mode (set if the game's depth is broken).";
    ui_category="Depth";
> = 0.6;

uniform float DepthGain <
    ui_type="slider"; ui_min=1.0; ui_max=512.0; ui_label="Depth Reject Gain";
    ui_category="Depth";
> = 128.0;

uniform float DepthEdgeRelief <
    ui_type="slider"; ui_min=0.0; ui_max=1.0; ui_label="Depth Edge Relief";
    ui_tooltip="Suppresses depth rejection on detected edges so it stops eating edge accumulation.\nSlow build runs this high. ~0.8-0.9.";
    ui_category="Depth";
> = 0.85;

uniform float EdgeScale <
    ui_type="slider"; ui_min=1.0; ui_max=12.0; ui_label="Edge Sensitivity";
    ui_tooltip="How readily local luma contrast counts as an edge. Raise if subtle horizontal\nedges crawl as you approach them. Runs a step higher assuming SMAA: softened\nedges produce smaller luma ranges. ~7-9.";
    ui_category="Depth";
> = 7.0;
#endif // TAA_USE_DEPTH

uniform int CombineMode <
    ui_type="combo"; ui_items="Union (max)\0Sum\0Depth-gated color\0";
    ui_label="Combine"; ui_category="Combine";
> = 0;

#if TAA_DEBUG
uniform int Debug <
    ui_type="combo"; ui_items="Off\0Reject\0Luma Motion\0Depth Signal\0Edge Mask\0Clip Distance\0Accum Count\0Flicker Mask\0";
    ui_label="Debug"; ui_category="Debug";
> = 0;
#endif

#if TAA_COMPACT_HISTORY
uniform uint FrameCount < source="framecount"; >;
// RGB10A2 + separate R8 N counter (the fast build's default). Halves history
// traffic; the dithered write keeps the 10-bit average converging, but this
// build's deep accumulation can still show faint banding in dark gradients.
texture texResolve  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGB10A2; };
texture texResolveN { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };
sampler sResolveN   { Texture=texResolveN; };
texture texPrevColor{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGB10A2; };
texture texPrevN    { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };
sampler sPrevN      { Texture=texPrevN; };
#else
// RGBA16F so the deep running average + N counter (in alpha) don't quantize
texture texResolve  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA16F; };
texture texPrevColor{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA16F; };
#endif
sampler sResolve    { Texture=texResolve; };
sampler sPrevColor  { Texture=texPrevColor; };
#if TAA_CHROMA_MOTION
texture texPrevRaw  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=RGBA8;   };
#else
texture texPrevRaw  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };  // luma only
#endif
sampler sPrevRaw    { Texture=texPrevRaw; };
#if TAA_DEBUG
// debug signal gets its own target: Resolve always writes the true history,
// so enabling a debug view no longer feeds the visualization back into itself
texture texDebug    { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };
sampler sDebug      { Texture=texDebug; };
#endif
#if TAA_FLICKER
// signed luma diff double-buffer for the alternation test (0.5 = no change)
texture texCurDiff  { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };
sampler sCurDiff    { Texture=texCurDiff; };
texture texPrevDiff { Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R8;      };
sampler sPrevDiff   { Texture=texPrevDiff; };
#endif
#if TAA_USE_DEPTH
// R16 UNORM, deliberately not float: linearized depth is 0..1, so uniform
// 1/65535 steps beat R16F's ~5e-4 far-field quantization 30x over, at half
// R32F's bandwidth. Even DepthGain 512 x one step stays under 1% false reject.
texture texPrevDepth{ Width=BUFFER_WIDTH; Height=BUFFER_HEIGHT; Format=R16;     };
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

    // neighborhood YUV stats: variance box always; luma range only when depth
    // is compiled in (it exists solely to feed the edge mask for relief)
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
    }
    float3 mean  = m1 / float(TAA_TAPS);
    float3 sigma = sqrt(max(m2/float(TAA_TAPS) - mean*mean, 0.0));
    float3 gamma = float3(GammaLuma, GammaChroma, GammaChroma);
    float3 mn = mean - gamma*sigma;
    float3 mx = mean + gamma*sigma;

    // clip-to-AABB rectification (replaces per-channel clamp)
    float3 hy   = toYUV(hist);
    float3 hyC  = clipToAABB(hy, mn, mx);
    float  clampDist   = distance(hy, hyC);          // luma-dominated staleness
    // bypass the YUV round-trip when nothing clipped: converged history stays bit-exact
    float3 histClamped = clampDist > 1e-6 ? fromYUV(hyC) : hist;

#if TAA_USE_DEPTH
    float edge = saturate((yMax - yMin) * EdgeScale);
#endif

    // signal 1: luma-weighted motion (luma diff kept SIGNED for the flicker test)
    float3 cy = toYUV(cur);
#if TAA_CHROMA_MOTION
    float3 py = toYUV(tex2D(sPrevRaw, uv).rgb);
    float sd        = cy.x - py.x;
    float colorDiff = saturate(((abs(sd) + ChromaWeight*length(cy.yz - py.yz)) - ColorFloor) * ColorGain);
#else
    float sd        = cy.x - tex2D(sPrevRaw, uv).x;        // R8 stores luma
    float colorDiff = saturate((abs(sd) - ColorFloor) * ColorGain);
#endif

#if TAA_FLICKER
    // flicker discriminator: successive signed diffs with a negative product
    // are oscillation (aliasing sizzle), not motion -> exempt from rejection
    // so the deep accumulation converges there
    float sdPrev  = tex2D(sPrevDiff, uv).x * 2.0 - 1.0;
    float flicker = saturate(-sd * sdPrev * FlickerSense);
    colorDiff *= 1.0 - FlickerSuppress * flicker;
#endif

    // signal 2: depth velocity, relieved on edges
#if TAA_USE_DEPTH
    float curD  = ReShade::GetLinearizedDepth(uv);
    float prevD = tex2D(sPrevDepth, uv).x;
    float depthVel = saturate(abs(curD - prevD) * DepthGain) * DepthConfidence;
    depthVel *= lerp(1.0, 1.0 - DepthEdgeRelief, edge);
#endif

    // combine
#if TAA_USE_DEPTH
    float reject;
    if      (CombineMode==0) reject = max(colorDiff, depthVel);
    else if (CombineMode==1) reject = saturate(colorDiff + depthVel);
    else                     reject = saturate(depthVel + colorDiff*(1.0-depthVel));
#else
    float reject = colorDiff;                          // depth stripped: color only
#endif
    reject = saturate(reject * RejectSoften);
    reject = max(reject, saturate(clampDist * ClampFeedback));

    // --- convergent accumulation ---
#if TAA_COMPACT_HISTORY
    float N = max(tex2D(sPrevN, uv).x * 64.0, 1.0);   // R8, scaled to slider max
#else
    float N = max(histA.a, 1.0);                      // frames accumulated so far
#endif
    float convWeight = rcp(N);                        // 1/N running-average weight
    float mixRate = max(convWeight, reject);          // reject overrides convergence
    mixRate = clamp(mixRate, Persistence, 1.0);

    float3 outRGB = itm( lerp(tm(histClamped), tm(cur), mixRate) );

    // update counter: grow toward cap, collapse on rejection
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
    oN     = Nnext * (1.0/64.0);      // scale matches Accum Cap slider max
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
    oColor = tex2D(sResolve, uv);                     // rgb (+ N when 16F) -> next history
#if TAA_COMPACT_HISTORY
    oN     = tex2D(sResolveN, uv).x;
#endif
#if TAA_CHROMA_MOTION
    oRaw   = float4(tex2D(ReShade::BackBuffer, uv).rgb, 1.0);
#else
    oRaw   = luma(tex2D(ReShade::BackBuffer, uv).rgb).xxxx;  // R8 target keeps .r
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

technique TAA_Hybrid_Perceptual_Quality
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