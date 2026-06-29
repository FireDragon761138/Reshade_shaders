# Reshade_shaders
These are some Reshade shaders I put together with the help of Anthropic Claude for retro gaming and creating retro-themed looks in games, aimed at late 90's to early 2000's PC and video games.

The NTSC_Blur is an abstract representation of cable, composite, and s-video television displays, meant to give a soft look.

CRT_glass_effects.fx is another abstract representation of halation and diffraction of light through a CRT tube's glass.  It pairs well with CRT.fx.

GringeFilter.fx is an attempt at the ubiquitous "piss filter" of mid 2000's gaming, warm yellow tone, desaturation and slightly lower contrast.  Good for games that look a little too pretty after processing.

AgX is a tonemapper curve meant to approximate the AgX tonemap, with desaturation inccreasing with luminance.  It produces a realistic film or video look without looking overbaked.

CalibrationPattern.fx is a collection of test patterns, such as pluge, gamma, and so on, meant to help judge ingame gamma and black level with different shader stacks.  It could be handy as not all games have gamma/brightness screens.

Retrolux is an "intelligent bloom" shader meant to emulate global illumination.  Good for older games with baked lighting and exposed depth buffer.



All shaders released under BSD simplified license.
