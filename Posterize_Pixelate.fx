/*
    Posterize + Pixelate

    No #include needed: no ReShade.fxh, no ReShadeUI.fxh, no PD80 headers,
    and no external texture files. Drop this single .fx anywhere on your
    effect search path and it compiles on its own.

    Inspired by prod80's PD80_06_Posterize_Pixelate, rewritten dependency-free:
      - Binds the backbuffer directly via the ": COLOR" semantic
        (that is exactly what ReShade::BackBuffer does under the hood).
      - Provides its own fullscreen-triangle vertex shader
        (instead of PostProcessVS from ReShade.fxh).
      - Uses ReShade's auto-defined BUFFER_* macros, which need no include.
      - Dithers with a selectable, texture-free dither (instead of the pd80
        noise PNGs): ordered Bayer, or noise-like dithers (IGN / white) for
        when the Bayer grid reads as too regular a pattern.
*/

//// UI /////////////////////////////////////////////////////////////////////////
uniform int number_of_levels <
    ui_type    = "slider";
    ui_label   = "Number of Levels";
    ui_tooltip = "Distinct values per color channel. 2 = harsh, 255 = effectively off.";
    ui_min     = 2;
    ui_max     = 255;
> = 8;

uniform int pixel_size <
    ui_type    = "slider";
    ui_label   = "Pixel Size";
    ui_tooltip = "Size of each pixel block in screen pixels. 1 = no pixelation.";
    ui_min     = 1;
    ui_max     = 32;
> = 4;

uniform float effect_strength <
    ui_type  = "slider";
    ui_label = "Effect Strength";
    ui_min   = 0.0;
    ui_max   = 1.0;
> = 1.0;

uniform bool enable_dither <
    ui_label   = "Enable Dithering";
    ui_tooltip = "Dither to hide posterization banding. No texture required.";
> = false;

uniform int dither_type <
    ui_type    = "combo";
    ui_label   = "Dither Type";
    ui_items   = "Bayer 4x4 (ordered pattern)\0Interleaved Gradient Noise\0White Noise (static)\0White Noise (animated)\0";
    ui_tooltip = "Bayer = regular grid. IGN = even procedural noise, no pattern\n"
                 "(recommended for a noisier, less patterned look).\n"
                 "White = fully random, grungier/clumpy.";
> = 1;

uniform float dither_strength <
    ui_type  = "slider";
    ui_label = "Dither Strength";
    ui_tooltip = "1.0 = one quantization step of dither. Higher over-drives it.";
    ui_min   = 0.0;
    ui_max   = 2.0;
> = 1.0;

uniform float timer < source = "timer"; >;   // ms, for animated white noise

//// BACKBUFFER (no ReShade.fxh) /////////////////////////////////////////////////
// The ": COLOR" semantic binds this texture to the game's backbuffer.
texture BackBufferTex : COLOR;
sampler BackBuffer { Texture = BackBufferTex; };

//// 4x4 BAYER MATRIX ////////////////////////////////////////////////////////////
// Classic ordered-dither threshold map, normalized to [0, 1).
static const float Bayer4x4[16] =
{
     0.0 / 16.0,  8.0 / 16.0,  2.0 / 16.0, 10.0 / 16.0,
    12.0 / 16.0,  4.0 / 16.0, 14.0 / 16.0,  6.0 / 16.0,
     3.0 / 16.0, 11.0 / 16.0,  1.0 / 16.0,  9.0 / 16.0,
    15.0 / 16.0,  7.0 / 16.0, 13.0 / 16.0,  5.0 / 16.0
};

// All dither sources return an offset centered on ~0, in roughly [-0.5, 0.5).

float bayerOffset( float2 cell )
{
    int2 c = int2( cell ) & 3;             // wrap into the 4x4 tile
    int  i = c.y * 4 + c.x;
    return ( Bayer4x4[i] + 0.5 / 16.0 ) - 0.5;
}

// Jorge Jimenez's Interleaved Gradient Noise - cheap, even, noise-like, no grid.
float ignOffset( float2 cell )
{
    float n = frac( 52.9829189 * frac( dot( cell, float2( 0.06711056, 0.00583715 ) ) ) );
    return n - 0.5;
}

// Plain hash white noise. 'seed' shifts it per frame when animated.
float whiteOffset( float2 cell, float seed )
{
    float n = frac( sin( dot( cell + seed, float2( 12.9898, 78.233 ) ) ) * 43758.5453 );
    return n - 0.5;
}

float ditherOffset( float2 cell )
{
    if ( dither_type == 0 ) return bayerOffset( cell );
    if ( dither_type == 1 ) return ignOffset( cell );
    if ( dither_type == 2 ) return whiteOffset( cell, 0.0 );
    return whiteOffset( cell, frac( timer * 0.001 ) * 100.0 );   // animated
}

//// FULLSCREEN VERTEX SHADER (no ReShade.fxh) ///////////////////////////////////
void FullscreenVS( in uint id : SV_VertexID,
                   out float4 pos : SV_Position,
                   out float2 texcoord : TEXCOORD )
{
    texcoord.x = ( id == 2 ) ? 2.0 : 0.0;
    texcoord.y = ( id == 1 ) ? 2.0 : 0.0;
    pos = float4( texcoord * float2( 2.0, -2.0 ) + float2( -1.0, 1.0 ), 0.0, 1.0 );
}

//// PIXEL SHADER ////////////////////////////////////////////////////////////////
float4 PS_PosterizePixelate( float4 vpos : SV_Position,
                             float2 texcoord : TEXCOORD ) : SV_Target
{
    float2 texelSize = float2( BUFFER_RCP_WIDTH, BUFFER_RCP_HEIGHT );

    // --- Pixelate: snap the sample to the center of each pixel block ---
    float2 blockSize = max( pixel_size, 1 ) * texelSize;
    float2 blockId   = floor( texcoord / blockSize );
    float2 sampleUV  = ( blockId + 0.5 ) * blockSize;

    float3 orig  = tex2D( BackBuffer, texcoord ).rgb;   // unmodified pixel (for blend)
    float3 color = tex2D( BackBuffer, sampleUV ).rgb;   // pixelated sample

    float lv = float( number_of_levels - 1 );

    // --- Optional dither: one offset per block so it stays pixel-sized ---
    if ( enable_dither )
    {
        float t = ditherOffset( blockId ) * dither_strength;
        color = saturate( color + t / lv );
    }

    // --- Posterize ---
    color = floor( color * lv + 0.5 ) / lv;

    // --- Blend back toward the original by effect strength ---
    color = lerp( orig, color, effect_strength );

    return float4( color, 1.0 );
}

//// TECHNIQUE ///////////////////////////////////////////////////////////////////
technique Posterize_Pixelate_Standalone
{
    pass
    {
        VertexShader = FullscreenVS;
        PixelShader  = PS_PosterizePixelate;
    }
}
