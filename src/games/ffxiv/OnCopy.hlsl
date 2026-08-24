#include "./shared.h"
#include "./DICE.hlsl"
#include "./psycho_test24.hlsli"
#include "./customtest25.hlsli"

// Restores the source color hue through Oklab (this works on colors beyond SDR in brightness and gamut too)
float3 RestoreHue(float3 targetColor, float3 sourceColor, float amount = 0.5)
{
  const float3 targetOklab = renodx::color::oklab::from::BT709(targetColor);
  const float3 targetOklch = renodx::color::oklch::from::OkLab(targetOklab);
  const float3 sourceOklab = renodx::color::oklab::from::BT709(sourceColor);

  // First correct both hue and chrominance at the same time (oklab a and b determine both, they are the color xy coordinates basically).
  // As long as we don't restore the hue to a 100% (which should be avoided), this will always work perfectly even if the source color is pure white (or black, any "hueless" and "chromaless" color).
  // This method also works on white source colors because the center of the oklab ab diagram is a "white hue", thus we'd simply blend towards white (but never flipping beyond it (e.g. from positive to negative coordinates)),
  // and then restore the original chrominance later (white still conserving the original hue direction).
  float3 correctedTargetOklab = float3(targetOklab.x, lerp(targetOklab.yz, sourceOklab.yz, amount));

  // Then restore chrominance
  float3 correctedTargetOklch = renodx::color::oklch::from::OkLab(correctedTargetOklab);
  correctedTargetOklch.y = targetOklch.y;

  return renodx::color::bt709::from::OkLCh(correctedTargetOklch);
}

// from Musa
float3 extendGamut(float3 color, float extendGamutAmount)
{
  float3 colorOKLab = renodx::color::oklab::from::BT709(color);

  // Extract L, C, h from OKLab
  float L = colorOKLab[0];
  float a = colorOKLab[1];
  float b = colorOKLab[2];
  float C = sqrt(a * a + b * b);
  float h = atan2(b, a);

  // Calculate the exponential weighting factor based on luminance and chroma
  float chromaWeight = 1.0f - exp(-4.0f * C);
  float luminanceWeight = 1.0f - exp(-4.0f * L * L);
  float weight = chromaWeight * luminanceWeight * extendGamutAmount;

  // Apply the expansion factor
  C *= (1.0f + weight);

  // Convert back to OKLab with adjusted chroma
  a = C * cos(h);
  b = C * sin(h);
  float3 adjustedOKLab = float3(L, a, b);

  float3 adjustedColor = renodx::color::bt709::from::OkLab(adjustedOKLab);
  float3 colorAP1 = renodx::color::ap1::from::BT709(adjustedColor);
  colorAP1 = max(0, colorAP1); // Clamp to AP1
  return renodx::color::bt709::from::AP1(colorAP1);
}

void OnCopy(inout float3 color)
{
  if (injectedData.copyTracker == 1) {
    // linearize
    color = renodx::math::SafePow(color, 2.2f);

    if (injectedData.toneMapType > 0) {      
      if (injectedData.toneMapType > 1) {
        float3 untonemapped = color;

        // PsychoV grades in its own LMS/MacLeod-Boynton domain, so the tone/purity
        // controls are handed to the tonemapper instead of being pre-applied here.
        bool isPsychoV24 = injectedData.toneMapType == 4;
        bool isPsychoV25 = injectedData.toneMapType == 5;
        bool isPsychoV = isPsychoV24 || isPsychoV25;

        // color grading
        renodx::color::grade::Config gradeConfig = renodx::color::grade::config::Create();
        gradeConfig.exposure = injectedData.colorGradeExposure;
        gradeConfig.highlights = isPsychoV ? 1.f : injectedData.colorGradeHighlights;
        gradeConfig.shadows = isPsychoV ? 1.f : injectedData.colorGradeShadows;
        gradeConfig.contrast = isPsychoV ? 1.f : injectedData.colorGradeContrast;
        gradeConfig.saturation = isPsychoV ? 1.f : injectedData.colorGradeSaturation;
        gradeConfig.dechroma = injectedData.colorGradeBlowout;
        gradeConfig.flare = injectedData.colorGradeFlare;
        gradeConfig.blowout = -1.f * (injectedData.colorGradeHighlightSaturation - 1.f);
        gradeConfig.hue_correction_strength = 0.f;
        color = renodx::color::grade::config::ApplyUserColorGrading(color, gradeConfig);
      
        // tonemap
        if (isPsychoV25) {
          color.rgb = ApplyCustomPsychoV25ToneMap(
              color.rgb,
              injectedData.toneMapPeakNits / injectedData.toneMapGameNits,  // peak_value
              injectedData.colorGradeHighlights,             // highlights
              injectedData.colorGradeShadows,                // shadows
              injectedData.colorGradeContrast,               // cone_response_exponent
              injectedData.colorGradeFlare,                  // flare
              injectedData.colorGradeSaturation,              // purity_scale
              injectedData.colorGradeHighlightSaturation,     // highlight_saturation
              injectedData.colorGradeBlowout,                 // dechroma
              0.18f.xxx,                                     // current_adaptive_state_bt709
              0.18f.xxx,                                     // current_background_state_bt709
              0.5f,                                          // pre_shoulder_hue_linearity
              0.35f,                                         // post_shoulder_source_hue_recovery_strength
              injectedData.psychoV25Compression,              // compression
              renodx::tonemap::psychov::PSYCHO25_TARGET_GAMUT_BT2020);  // target_gamut_mode
        } else if (isPsychoV24) {
          color.rgb = renodx_custom::tonemap::psycho24::psychotm_test24(
              color.rgb,
              injectedData.toneMapPeakNits / injectedData.toneMapGameNits,  // peak_value
              1.f,                                 // exposure (already applied above)
              injectedData.colorGradeHighlights,   // highlights
              injectedData.colorGradeShadows,      // shadows
              injectedData.colorGradeContrast,     // contrast
              injectedData.colorGradeSaturation,   // purity_scale
              1.f,                                 // bleaching_intensity (reserved)
              100.f,                               // clip_point (reserved)
              1.f,                                 // hue_restore (unused in test24)
              1.f,                                 // adaptation_contrast (deprecated)
              0,                                   // white_curve_mode (deprecated)
              1.f,                                 // cone_response_exponent
              0.18f.xxx,                           // anchor-in
              0.18f.xxx,                           // anchor-out
              1.f,                                 // gamut_compression
              1,                                   // gamut compression mode: BT.2020
              1.f,                                 // adaptive_normalization (deprecated)
              injectedData.psychoVCompression,     // curve-to-white pow, 0 = auto
              1.f,                                 // highlight_saturation (declared but unused in test24)
              injectedData.psychoVGamutHueRestore);  // OKLab hue restore after gamut compression
        } else if (injectedData.toneMapType == 3) {
          renodx::tonemap::renodrt::Config config = renodx::tonemap::renodrt::config::Create();
          config.nits_peak = (injectedData.toneMapPeakNits / injectedData.toneMapGameNits) * 100.f;
          config.tone_map_method = injectedData.renoDRTToneMapMethod;
          // Only the non-Daniele curves read white_clip; Daniele ignores it entirely.
          config.white_clip = injectedData.renoDRTWhiteClip;
          // Disabled so highlight desaturation only comes from the color grading dechroma (Blowout),
          // keeping this comparable to the DICE path, which has no equivalent post-tonemap dechroma.
          config.dechroma = 0.f;
          color.rgb = renodx::tonemap::renodrt::BT709(color.rgb, config);
        } else {
          DICESettings config = DefaultDICESettings();
          config.Type = 3;
          config.ShoulderStart = injectedData.diceShoulderStart;

          float dicePaperWhite = injectedData.toneMapGameNits / 80.f;
          float dicePeakWhite = injectedData.toneMapPeakNits / 80.f;
          color.rgb = DICETonemap(color.rgb * dicePaperWhite, dicePeakWhite, config) / dicePaperWhite;
        }

        color = renodx::color::correct::Hue(color, renodx::tonemap::uncharted2::BT709(untonemapped), injectedData.hueCorrectionStrength);

        color = extendGamut(color, injectedData.gamutExpansion);
      }
    }

    // apply game paperwhite brightness with inverse UI brightness (ui brightness is re-applied in the final shader)
    color *= injectedData.toneMapGameNits / injectedData.toneMapUINits;

    // back to gamma space
    color = renodx::math::SafePow(color, 1.f / 2.2f);
  }
}