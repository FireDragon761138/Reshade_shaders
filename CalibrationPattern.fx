/*=============================================================================

    CalibrationPattern.fx  -  Display / ReShade calibration test patterns

    Drop this file into your   ...\reshade-shaders\Shaders\   folder, open the
    ReShade overlay (Home key by default) and enable "Calibration Test
    Patterns". Pick a pattern from the drop-down. It fully REPLACES the screen
    so you can calibrate brightness / black point / gamma / contrast, then turn
    it back off when you're done.

    Patterns
      0  Black level / shadow detail .. 16 bars, code value 0..15. Raise display
                                        brightness (black point) until you can
                                        just distinguish bars 1,2,3 from black.
      1  White level / highlights ..... 16 bars, code 240..255. Lower contrast/
                                        white level until you can see 254 & 255
                                        as distinct (no white crush).
      2  Grayscale staircase ........... even steps 0..1; check for tint & even
                                        spacing (no crushing at either end).
      3  Gamma match ................... find the patch that blends into the
                                        line field. Top->bottom = gamma
                                        1.8 / 2.0 / 2.2 / 2.4 / 2.6.
      4  Color bars (75%) .............. white,yellow,cyan,green,magenta,red,
                                        blue,black at 75%.
      5  Smooth gradient ............... look for banding / posterization.
      6  Contrast windows .............. white box on black + black box on white.
      7  Sharpness / grid .............. 1/2/4 px checkers; spot ringing & scaling.
      8  Solid fill .................... whole screen at the "Level" slider value
                                        (for a colorimeter / tint check).
      9  PLUGE (classic) ............... left bar darker, right bar lighter than
                                        the field. Lower brightness until the
                                        LEFT bar just disappears while the RIGHT
                                        bar stays barely visible.

=============================================================================*/

#include "ReShade.fxh"

uniform int iPattern <
    ui_type  = "combo";
    ui_label = "Test Pattern";
    ui_items = "Black level / shadow detail\0White level / highlights\0Grayscale staircase\0Gamma match (1.8 - 2.6)\0Color bars (75%)\0Smooth gradient (banding)\0Contrast windows\0Sharpness / grid\0Solid fill\0PLUGE (classic)\0";
> = 0;

uniform float fLevel <
    ui_type  = "slider";
    ui_label = "Solid fill level";
    ui_tooltip = "Only used by the 'Solid fill' pattern.";
    ui_min = 0.0; ui_max = 1.0; ui_step = 0.001;
> = 0.5;

uniform int iSteps <
    ui_type  = "slider";
    ui_label = "Grayscale steps";
    ui_tooltip = "Only used by the 'Grayscale staircase' pattern.";
    ui_min = 2; ui_max = 32;
> = 11;

uniform bool bBorder <
    ui_label = "Show 1px white frame";
    ui_tooltip = "Confirms the pattern covers the whole screen (no overscan).";
> = false;

// ---------------------------------------------------------------------------

float3 v(float x) { return float3(x, x, x); }

// parity of an integer-valued float: 0.0 if even, 1.0 if odd (avoids fmod/%)
float parity(float x) { return frac(x * 0.5) * 2.0; }

float3 PatternColor(float2 uv)
{
    float2 px = uv * float2(BUFFER_WIDTH, BUFFER_HEIGHT);

    // 0 - Black level / shadow detail : code values 0..15 in 16 columns
    if (iPattern == 0)
    {
        int n = (int)floor(uv.x * 16.0);
        return v((float)n / 255.0);
    }

    // 1 - White level / highlights : code values 240..255 in 16 columns
    if (iPattern == 1)
    {
        int n = (int)floor(uv.x * 16.0);
        return v((240.0 + (float)n) / 255.0);
    }

    // 2 - Grayscale staircase
    if (iPattern == 2)
    {
        int steps = max(iSteps, 2);
        int n = min((int)floor(uv.x * steps), steps - 1);
        return v((float)n / (float)(steps - 1));
    }

    // 3 - Gamma match : line field with embedded solid patches
    if (iPattern == 3)
    {
        // 1px alternating black/white lines -> averages to 0.5 linear luminance
        float line = (parity(floor(px.y)) < 0.5) ? 1.0 : 0.0;

        // five patches stacked vertically in the centre, each = 0.5^(1/gamma)
        static const float gammas[5] = { 1.8, 2.0, 2.2, 2.4, 2.6 };
        if (uv.x > 0.40 && uv.x < 0.60)
        {
            float band = (uv.y - 0.10) / 0.16; // 0..5 across y in [0.10,0.90]
            int i = (int)floor(band);
            if (i >= 0 && i < 5)
            {
                float fracpart = frac(band);
                if (fracpart > 0.12 && fracpart < 0.88)   // leave gaps of lines
                    return v(pow(0.5, 1.0 / gammas[i]));
            }
        }
        return v(line);
    }

    // 4 - Color bars (75%)
    if (iPattern == 4)
    {
        int b = (int)floor(uv.x * 8.0);
        const float L = 0.75;
        if (b == 0) return float3(L, L, L); // white
        if (b == 1) return float3(L, L, 0); // yellow
        if (b == 2) return float3(0, L, L); // cyan
        if (b == 3) return float3(0, L, 0); // green
        if (b == 4) return float3(L, 0, L); // magenta
        if (b == 5) return float3(L, 0, 0); // red
        if (b == 6) return float3(0, 0, L); // blue
        return float3(0, 0, 0);             // black
    }

    // 5 - Smooth horizontal gradient
    if (iPattern == 5)
        return v(uv.x);

    // 6 - Contrast windows : white box on black (left) + black box on white (right)
    if (iPattern == 6)
    {
        bool inBox = (frac(uv.x * 2.0) > 0.30 && frac(uv.x * 2.0) < 0.70
                   && uv.y > 0.30 && uv.y < 0.70);
        if (uv.x < 0.5)  return inBox ? v(1.0) : v(0.0);
        else             return inBox ? v(0.0) : v(1.0);
    }

    // 7 - Sharpness / grid : 1px | 2px | 4px checkers across thirds
    if (iPattern == 7)
    {
        float cell = (uv.x < 1.0 / 3.0) ? 1.0 : (uv.x < 2.0 / 3.0) ? 2.0 : 4.0;
        float c = parity(floor(px.x / cell) + floor(px.y / cell));
        return v(c);
    }

    // 8 - Solid fill
    if (iPattern == 8)
        return v(fLevel);

    // 9 - PLUGE (classic) : field with a darker and a lighter bar
    if (iPattern == 9)
    {
        float field = 8.0 / 255.0;   // near-black reference field
        if (uv.x > 0.36 && uv.x < 0.44) return v(4.0  / 255.0); // "blacker"
        if (uv.x > 0.56 && uv.x < 0.64) return v(12.0 / 255.0); // "whiter"
        return v(field);
    }

    return v(0.0);
}

float3 PS_Calibration(float4 vpos : SV_Position, float2 texcoord : TEXCOORD) : SV_Target
{
    float3 col = PatternColor(texcoord);

    if (bBorder)
    {
        float2 px = texcoord * float2(BUFFER_WIDTH, BUFFER_HEIGHT);
        if (px.x < 1.0 || px.y < 1.0 ||
            px.x > BUFFER_WIDTH - 1.0 || px.y > BUFFER_HEIGHT - 1.0)
            col = float3(1.0, 1.0, 1.0);
    }

    return col;
}

technique CalibrationPattern <
    ui_label   = "Calibration Test Patterns";
    ui_tooltip = "Full-screen test patterns for calibrating brightness, black level, gamma and contrast. Enable, calibrate, then disable.";
>
{
    pass
    {
        VertexShader = PostProcessVS;
        PixelShader  = PS_Calibration;
    }
}
