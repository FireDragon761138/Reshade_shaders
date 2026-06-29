/*
    Posterize + Pixelate (PSX edition) - fully self-contained ReShade effect.

    Zero dependencies: no ReShade.fxh, no ReShadeUI.fxh, no PD80 headers,
    and no external texture files. Drop this single .fx on your effect
    search path and it compiles on its own.

    This version replaces the procedural hash dither with a 4x4 Bayer
    ORDERED dither - the exact pattern the PlayStation's GPU used to fake
    extra colors out of its 15-bit (5 bits/channel) framebuffer.

    Defaults are tuned for a PSX look at 1080p:
      Number of Levels = 32  -> 15-bit color (32 shades per channel)
      Pixel Size       = 6   -> ~320x240 internal resolution
      Dithering        = on  -> the signature PS1 cross-hatch
*/

//// UI /////////////////////////////////////////////////////////////////////////
uniform int number_of_levels <
    ui_type    = "slider";
    ui_label   = "Number of Levels";
    ui_tooltip = "Distinct values per color channel. 32 = authentic PSX 15-bit color.";
    ui_min     = 2;
    ui_max     = 255;
> = 32;

uniform int pixel_size <
    ui_type    = "slider";
    ui_label   = "Pixel Size";
    ui_tooltip = "Size of each pixel block in screen pixels. ~6 mimics 320x240 at 1080p.";
    ui_min     = 1;
    ui_max     = 32;
> = 6;

uniform float effect_strength <
    ui_type  = "slider";
    ui_label = "Effect Strength";
    ui_min   = 0.0;
    ui_max   = 1.0;
> = 1.0;

uniform bool enable_dither <
    ui_label   = "Enable Dithering";
    ui_tooltip = "4x4 Bayer ordered dither - the real PlayStation pattern. No texture required.";
> = true;

uniform float dither_strength <
    ui_type  = "slider";
    ui_label = "Dither Strength";
    ui_tooltip = "1.0 = textbook ordered dither. Higher over-drives the pattern.";
    ui_min   = 0.0;
    ui_max   = 2.0;
> = 1.0;

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

// Returns a dither offset centered on zero, in roughly [-0.5, 0.5).
float bayerOffset( float2 cell )
{
    int2 c  = int2( cell ) & 3;            // wrap into the 4x4 tile
    int  i  = c.y * 4 + c.x;
    return ( Bayer4x4[i] + 0.5 / 16.0 ) - 0.5;
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

    // --- Ordered dither on the low-res grid, the way the PSX framebuffer did it ---
    if ( enable_dither )
    {
        float t = bayerOffset( blockId ) * dither_strength;
        color = saturate( color + t / lv );
    }

    // --- Posterize ---
    color = floor( color * lv + 0.5 ) / lv;

    // --- Blend back toward the original by effect strength ---
    color = lerp( orig, color, effect_strength );

    return float4( color, 1.0 );
}

//// TECHNIQUE ///////////////////////////////////////////////////////////////////
technique Posterize_Pixelate_PSX
{
    pass
    {
        VertexShader = FullscreenVS;
        PixelShader  = PS_PosterizePixelate;
    }
}
