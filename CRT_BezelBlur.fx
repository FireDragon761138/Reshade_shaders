/*=============================================================================

    CRT_BezelBlur.fx
    ----------------------------------------------------------------------------
    A thin bezel rim for the CRT_TV_Lite tube: a narrow band around the picture
    edge where the image is gently DARKENED toward the edge, with the corners
    rounded off to black like a tube faceplate. (No blur - purely darkening.)

    One curvature-aware ROUNDED-rectangle distance field to the tube edge (the same
    [0,1] box CRT_TV_Lite feathers, bent by the same barrel warp) drives it:

        * DARKEN   - the picture dims across a thin band as it nears the edge,
                     giving the rim a shaded, recessed look.
        * CORNERS  - everything past the rounded edge fades to black. On the
                     straight sides that's already the black surround (no change);
                     at the corners it's picture, so the square tip is rounded off.
                     The dark cutoff edge can be ordered-dithered (CRT_Royale style)
                     to stipple it and kill banding.

    Everything is a fraction of SCREEN HEIGHT, so the thin rim keeps the same
    relative width at any resolution.

    CURVATURE: type the SAME Curvature X / Y you set in CRT_TV_Lite so the rim
    follows the tube. (ReShade can't share a value between effects.) 0 = straight.

    Run it LAST:  NTSC_TV -> CRT_TV_Lite -> CRT_glass_effects -> CRT_BezelBlur

=============================================================================*/

#include "ReShade.fxh"

// --------------------------------------------------------------------------
// Controls
// --------------------------------------------------------------------------
uniform float warpX <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.125; ui_step = 0.01;
    ui_label = "Curvature X";
    ui_category = "Curvature (match CRT_TV_Lite)";
    ui_tooltip = "Set to the SAME value as CRT_TV_Lite's Curvature X.";
> = 0.0;

uniform float warpY <
    ui_type = "slider"; ui_min = 0.0; ui_max = 0.125; ui_step = 0.01;
    ui_label = "Curvature Y";
    ui_category = "Curvature (match CRT_TV_Lite)";
    ui_tooltip = "Set to the SAME value as CRT_TV_Lite's Curvature Y.";
> = 0.0;

uniform float PictureAspect <
    ui_type = "slider";
    ui_min = 1.0; ui_max = 2.40; ui_step = 0.0001;
    ui_label = "Picture Aspect";
    ui_tooltip = "Aspect ratio (width:height) of the actual game picture the bezel\n"
                 "wraps. THPS3 is 4:3 = 1.3333. The bezel fits the largest box of this\n"
                 "ratio centred in the frame, so it rounds the PICTURE corners, not\n"
                 "the black pillarbox/letterbox bars around it.";
    ui_category = "Bezel";
> = 1.3333;

uniform float BezelWidth <
    ui_type = "slider";
    ui_min = 0.004; ui_max = 0.10; ui_step = 0.002;
    ui_label = "Bezel Width";
    ui_tooltip = "Width of the darkened rim - how far the dimming reaches in from\n"
                 "the edge, as a fraction of screen height. Keep it small for a\n"
                 "thin bezel.";
    ui_category = "Bezel";
> = 0.015;

uniform float Darkness <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Darkness";
    ui_tooltip = "How much the rim dims the picture toward the edge.\n"
                 "0 = no dimming (corners still round to black); 1 = rim goes fully\n"
                 "dark at the edge.";
    ui_category = "Bezel";
> = 0.40;

uniform float CornerRadius <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 0.20; ui_step = 0.002;
    ui_label = "Corner Radius";
    ui_tooltip = "How much the corners are rounded, as a fraction of screen height.\n"
                 "0 = square corners.";
    ui_category = "Bezel";
> = 0.050;

uniform float CornerDither <
    ui_type = "slider";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.01;
    ui_label = "Edge Dither";
    ui_tooltip = "Stipples the dark cutoff edge with an ordered 8x8 pattern to break\n"
                 "up banding (the CRT_Royale look). 0 = clean edge.";
    ui_category = "Bezel";
> = 0.50;

// --------------------------------------------------------------------------
// Barrel distortion, identical to CRT_TV_Lite's Warp().
float2 Warp(float2 uv)
{
    float2 c = uv * 2.0 - 1.0;
    c *= float2(1.0 + c.y * c.y * warpX,
                1.0 + c.x * c.x * warpY);
    return c * 0.5 + 0.5;
}

// Ordered 8x8 Bayer matrix (0..63). static const per reshadefx.
static const float Bayer8[64] = {
     0.0, 32.0,  8.0, 40.0,  2.0, 34.0, 10.0, 42.0,
    48.0, 16.0, 56.0, 24.0, 50.0, 18.0, 58.0, 26.0,
    12.0, 44.0,  4.0, 36.0, 14.0, 46.0,  6.0, 38.0,
    60.0, 28.0, 52.0, 20.0, 62.0, 30.0, 54.0, 22.0,
     3.0, 35.0, 11.0, 43.0,  1.0, 33.0,  9.0, 41.0,
    51.0, 19.0, 59.0, 27.0, 49.0, 17.0, 57.0, 25.0,
    15.0, 47.0,  7.0, 39.0, 13.0, 45.0,  5.0, 37.0,
    63.0, 31.0, 55.0, 23.0, 61.0, 29.0, 53.0, 21.0
};

float DitherValue(float2 vpos)
{
    int2 ip = int2(vpos) & 7;
    return Bayer8[ip.y * 8 + ip.x] * (1.0 / 64.0);
}

// Signed distance to the rounded PICTURE edge (curvature-aware, height-normalized).
// The picture is the largest PictureAspect box centred in the frame, so the bezel
// wraps the real image and ignores the black pillarbox/letterbox bars around it.
// <0 inside the picture, 0 on the edge, >0 out in the surround.
float EdgeSDF(float2 uv)
{
    float2 pos = Warp(uv);
    float  bufferAspect = float(BUFFER_WIDTH) / float(BUFFER_HEIGHT);
    float2 p = pos - 0.5;
    p.x *= bufferAspect;                             // height-normalized square units

    // Half-size of the centred PictureAspect box, in height units. Pillarboxed when
    // the frame is wider than the picture, letterboxed when it's taller.
    float2 halfExtent = (bufferAspect >= PictureAspect)
        ? float2(0.5 * PictureAspect, 0.5)
        : float2(0.5 * bufferAspect, 0.5 * bufferAspect / PictureAspect);

    float  radius = min(CornerRadius, min(halfExtent.x, halfExtent.y));
    float2 d  = abs(p) - (halfExtent - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

float3 PS_Bezel(float4 vpos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float  sd  = EdgeSDF(uv);
    float3 col = tex2D(ReShade::BackBuffer, uv).rgb;

    // Rim darkening: dim toward the edge across the thin band.
    float rim  = smoothstep(-BezelWidth, 0.0, sd);   // 0 deep inside -> 1 at edge
    float dark = 1.0 - Darkness * rim;

    // Black cutoff past the rounded edge (rounds corners, ends the surround), with
    // an optional dithered edge. Softness tracks the bezel width so it stays thin.
    float bsoft  = max(BezelWidth * 0.6, 1e-5);
    float jitter = (DitherValue(vpos.xy) - 0.5) * CornerDither * bsoft;
    float black  = 1.0 - smoothstep(0.0, bsoft, sd + jitter);

    return col * dark * black;
}

technique CRT_BezelBlur <
    ui_tooltip = "Thin darkened bezel rim with rounded, blacked-off corners.\n"
                 "Run LAST in the chain.";
>
{
    pass Bezel { VertexShader = PostProcessVS; PixelShader = PS_Bezel; }
}
