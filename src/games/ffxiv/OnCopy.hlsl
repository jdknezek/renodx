#include "./shared.h"
#include "./DICE.hlsl"
#include "./customtest31.hlsli"

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
        bool isPsychoV = injectedData.toneMapType == 4;

        // color grading
        renodx::color::grade::Config gradeConfig = renodx::color::grade::config::Create();
        gradeConfig.exposure = injectedData.colorGradeExposure;
        gradeConfig.highlights = isPsychoV ? 1.f : injectedData.colorGradeHighlights;
        gradeConfig.shadows = isPsychoV ? 1.f : injectedData.colorGradeShadows;
        gradeConfig.contrast = isPsychoV ? 1.f : injectedData.colorGradeContrast;
        gradeConfig.saturation = isPsychoV ? 1.f : injectedData.colorGradeSaturation;
        gradeConfig.dechroma = isPsychoV ? 0.f : injectedData.colorGradeBlowout;
        gradeConfig.flare = isPsychoV ? 0.f : injectedData.colorGradeFlare;
        gradeConfig.blowout = isPsychoV ? 0.f : -1.f * (injectedData.colorGradeHighlightSaturation - 1.f);
        gradeConfig.hue_correction_strength = 0.f;
        color = renodx::color::grade::config::ApplyUserColorGrading(color, gradeConfig);
      
        // tonemap
        if (isPsychoV) {
          color.rgb = renodx::tonemap::psychov::custom_psychotm_test31(
              color.rgb,
              injectedData.toneMapPeakNits / injectedData.toneMapGameNits,  // peak_value
              1.f,                                           // exposure (already applied above)
              injectedData.colorGradeHighlights,             // highlights
              injectedData.colorGradeShadows,                // shadows
              injectedData.colorGradeContrast,               // contrast
              injectedData.colorGradeFlare,                  // flare
              1.f,                                           // highlight_contrast
              1.f,                                           // shadow_contrast
              injectedData.colorGradeSaturation,             // purity_scale
              injectedData.colorGradeHighlightSaturation,    // highlight_saturation
              injectedData.colorGradeBlowout,                // dechroma
              0.18f.xxx,                                     // current_adaptive_state_bt709
              0.18f.xxx,                                     // current_background_state_bt709
              0.f,                                           // sdr_eotf_emulation
              1.f,                                           // gamut_compression
              renodx::tonemap::psychov::CUSTOM_PSYCHO31_TARGET_GAMUT_BT2020,  // gamut_compression_mode
              injectedData.psychoVCompression);              // compression
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