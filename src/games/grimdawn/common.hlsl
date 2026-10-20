#include "./shared.h"
#include "./customtest31.hlsli"
//#include "./lilium_rcas.hlsl"

/// Applies Exponential Roll-Off tonemapping using the maximum channel.
/// Used to fit the color into a 0–output_max range for SDR LUT compatibility.
float3 ToneMapMaxCLL(float3 color, float rolloff_start = 1.0f, float output_max = 100.f) {
  if (RENODX_TONE_MAP_TYPE == 0.f) {
    return saturate(color);
  }
  color = min(color, 100.f);
  float peak = max(color.r, max(color.g, color.b));
  peak = min(peak, 100.f);
  float log_peak = log2(peak);

  // Apply exponential shoulder in log space
  float log_mapped = renodx::tonemap::ExponentialRollOff(log_peak, log2(rolloff_start), log2(output_max));
  float scale = exp2(log_mapped - log_peak);  // How much to compress all channels

  return min(output_max, color * scale);
}

float3 ToneMapMaxCLLClip(float3 color, float rolloff_start = 0.75f, float output_max = 1.f, float white_clip = 100.f) {
  if (RENODX_TONE_MAP_TYPE == 0.f) {
    return color;
  }
  color = min(color, 100.f);
  float peak = max(color.r, max(color.g, color.b));
  peak = min(peak, 100.f);
  float log_peak = log2(peak);
  float white_clip_log = log2(white_clip);

  // Apply exponential shoulder in log space
  float log_mapped = renodx::tonemap::ExponentialRollOff(log_peak, log2(rolloff_start), log2(output_max), white_clip_log);
  float scale = exp2(log_mapped - log_peak);  // How much to compress all channels

  return min(output_max, color * scale);
}

float3 HermiteSplineMaxCLL(float3 color, float tonemap_peak, float white_clip) {
  float rgb_max = renodx::math::Max(color);
  float rgb_max_log = log2(rgb_max);
  float tonemap_peak_log = log2(tonemap_peak);

  float tonemapped_log = renodx::tonemap::HermiteSplineRolloff(rgb_max_log, tonemap_peak_log, log2(white_clip));
  float tonemapped = exp2(tonemapped_log);

  float scale = renodx::math::DivideSafe(tonemapped, rgb_max, 1.f);
  return color * scale;
}

float3 ReinhardPiecewiseExtendedMaxCLL(float3 color, float rolloff_start, float tonemap_peak, float white_clip) {
  float rgb_max = renodx::math::Max(color);
  //float rgb_max = renodx::color::y::from::BT709(color); // by luminance for testing
  float rgb_max_log = log2(rgb_max);
  float tonemap_peak_log = log2(tonemap_peak);

  float tonemapped_log = renodx::tonemap::ReinhardPiecewiseExtended(rgb_max_log, log2(white_clip), tonemap_peak_log, log2(rolloff_start));
  float tonemapped = exp2(tonemapped_log);

  float scale = renodx::math::DivideSafe(tonemapped, rgb_max, 1.f);
  return color * scale;
}

float ComputeReinhardSmoothClampScale(float3 untonemapped, float rolloff_start = 0.375f, float output_max = 1.f, float white_clip = 100.f) {
  if (RENODX_TONE_MAP_TYPE == 0.f) return 1.f;
  float peak = renodx::math::Max(untonemapped);
  float mapped_peak = renodx::tonemap::ReinhardPiecewiseExtended(peak, white_clip, output_max, rolloff_start);
  float scale = renodx::math::DivideSafe(mapped_peak, peak, 1.f);

  return scale;
}

void GamutCompression(inout float3 color, inout float compression_scale) {
  color = renodx::color::bt709::clamp::AP1(color);
  float3 gamma_color = renodx::color::gamma::EncodeSafe(color);
  float grayscale = renodx::color::y::from::BT709(gamma_color.rgb);
  compression_scale = renodx::color::correct::ComputeGamutCompressionScale(gamma_color.rgb, grayscale);
  gamma_color = renodx::color::correct::GamutCompress(gamma_color, grayscale, compression_scale);
  color = renodx::color::gamma::DecodeSafe(gamma_color);
  color = renodx::color::bt709::clamp::BT709(color);
}

void GamutDecompression(inout float3 color, float compression_scale) {
  color = renodx::color::bt709::clamp::BT709(color);
  float3 gamma_color = renodx::color::gamma::EncodeSafe(color);
  gamma_color = renodx::color::correct::GamutDecompress(gamma_color, compression_scale);
  color = renodx::color::gamma::DecodeSafe(gamma_color);
}

float HDRBoost(float color, float power = 0.20f, float normalization_point = 0.02f) {
  const float smoothing = power * 2.f;

  float boosted = max(color, lerp(color, normalization_point * pow(color / normalization_point, 1.f + power), renodx::tonemap::Reinhard(color, smoothing)));
  // float highlight_compression_scale = saturate(pow(saturate((color - highlight_compression_start) / (highlight_compression_peak - highlight_compression_start)), highlight_compression_curve));
  // float smoothed = lerp(boosted, color, highlight_compression_scale);
  return boosted;
  //return smoothed;
}

float3 HDRBoost(float3 color, float power = 0.20f, float normalization_point = 0.02f) {
  return float3(
      HDRBoost(color.r, power, normalization_point),
      HDRBoost(color.g, power, normalization_point),
      HDRBoost(color.b, power, normalization_point)
  );
}

float3 ApplyHDRBoost(float3 color, float power = 0.20f, int mode = 0, float normalization_point = 0.02f) {
  if (power == 0.f) return color;

  color = max(0, renodx::color::bt2020::from::BT709(color));

  if (mode == 0) {  // Per Channel
    //color = HDRBoost(color, power, normalization_point);
    //color = renodx::tonemap::ReinhardPiecewiseExtended(color, HDRBoost(100.f, power, normalization_point), 100.f, 1.f);
    //color = ToneMapMaxCLLClip(color, 1.f, 100.f, HDRBoost(100.f, power, normalization_point));
  } 
  else if (mode == 1) {  // By Luminance
    float y_in = renodx::color::y::from::BT709(color);
    float y_out = HDRBoost(y_in, power, normalization_point);
    //float y_out = BoostHDR(y_in, 10.f, power, 0.18f);
    //y_out = exp2(renodx::tonemap::ExponentialRollOff(log2(y_out), log2(1.f), log2(100.f), log2(HDRBoost(100.f, power, normalization_point))));
    color = renodx::color::correct::Luminance(color, y_in, y_out);
    // color = ToneMapMaxCLLClip(color, 1.f, 100.f, HDRBoost(100.f, power, normalization_point));
    //color = NeuTwoMaxCLL(color, 100.f, HDRBoost(100.f, power, normalization_point));
    //color = HermiteSplineMaxCLL(color, 100.f, HDRBoost(100.f, power, normalization_point));
    //color = ReinhardPiecewiseExtendedMaxCLL(color, 100.f, HDRBoost(100.f, power, normalization_point));
  }

  color = renodx::color::bt709::from::BT2020(color);
  return color;
}

float3 ApplyExposureContrastFlareHighlightsShadowsByLuminance(float3 untonemapped, float y, renodx::color::grade::Config config, float mid_gray = 0.18f) {
  if (config.exposure == 1.f && config.shadows == 1.f && config.highlights == 1.f && config.contrast == 1.f && config.flare == 0.f) {
    return untonemapped;
  }
  float3 color = untonemapped;

  color *= config.exposure;

  // contrast & flare
  const float y_normalized = y / mid_gray;
  float flare = renodx::math::DivideSafe(y_normalized + config.flare, y_normalized, 1.f);
  float exponent = config.contrast * flare;
  const float y_contrasted = pow(y_normalized, exponent) * mid_gray;

  // highlights
  float y_highlighted = renodx::color::grade::Highlights(y_contrasted, config.highlights, mid_gray);

  // shadows
  float y_shadowed = renodx::color::grade::Shadows(y_highlighted, config.shadows, mid_gray);
  y_shadowed = max(0, y_shadowed); //clamp to prevent artifacts

  const float y_final = y_shadowed;

  color = renodx::color::correct::Luminance(color, y, y_final);

  return color;
}

float3 ApplySaturationBlowoutHighlightSaturation(float3 tonemapped, float y, renodx::color::grade::Config config) {
  float3 color = tonemapped;
  if (config.saturation != 1.f || config.dechroma != 0.f || config.blowout != 0.f) {
    float3 perceptual_new = renodx::color::oklab::from::BT709(color);

    if (config.dechroma != 0.f) {
      perceptual_new.yz *= lerp(1.f, 0.f, saturate(pow(y / (10000.f / 100.f), (1.f - config.dechroma))));
      //perceptual_new.yz *= lerp(1.f, 0.f, saturate(pow(exp2(y) / (10000.f / 100.f), (1.f - config.dechroma))));
    }

    if (config.blowout != 0.f) {
      float percent_max = saturate(y * 100.f / 10000.f);
      // positive = 1 to 0, negative = 1 to 2
      float blowout_strength = 100.f;
      float blowout_change = pow(1.f - percent_max, blowout_strength * abs(config.blowout));
      if (config.blowout < 0) {
        blowout_change = (2.f - blowout_change);
      }

      perceptual_new.yz *= blowout_change;
    }

    perceptual_new.yz *= config.saturation;

    color = renodx::color::bt709::from::OkLab(perceptual_new);

    color = renodx::color::bt709::clamp::AP1(color);
  }
  return color;
}

float3 ApplyPerChannelBlowoutHueShiftHueClip(float3 untonemapped, float mid_gray = 0.18f, float sdr_max = 1.f) {
  if (RENODX_SWAP_CHAIN_OUTPUT_PRESET == 0.f) return untonemapped;

  float max_clip = 100.f;
  float3 color = untonemapped;

  //color = max(0, renodx::color::bt2020::from::BT709(color));

  if (SCENE_GRADE_HUE_CLIP > 0.f) {
    float3 hue_clipped_color = renodx::tonemap::ExponentialRollOff(color, 1.75f, 2.f);
    color = renodx::color::correct::Hue(color, hue_clipped_color, SCENE_GRADE_HUE_CLIP, 0);
  }

  if (SCENE_GRADE_PER_CHANNEL_BLOWOUT > 0.f) {
    max_clip = SCENE_GRADE_PER_CHANNEL_BLOWOUT;
    float calculated_peak = max_clip + (sdr_max - 1.f);
    calculated_peak = max(calculated_peak, 1.f);

    // float calculated_peak_log = log2(calculated_peak);
    // float mid_gray_log = log2(mid_gray);
    // float3 untonemapped_log = log2(color);

    //untonemapped = max(0, renodx::color::bt2020::from::BT709(untonemapped));

    float3 graded_color = renodx::tonemap::ReinhardPiecewise(color, calculated_peak, mid_gray);
    //float3 graded_color = renodx::tonemap::HermiteSplinePerChannelRolloff(color, calculated_peak, 100.f);
    color = renodx::color::correct::Chrominance(color, graded_color, 1.f, 0.f, 1);
    color = renodx::color::correct::Hue(color, graded_color, SCENE_GRADE_PER_CHANNEL_HUE_SHIFT, 1);
  }
  //color = renodx::color::bt709::from::BT2020(color);
  return color;
}


float3 PreTonemapSliders(float3 untonemapped) {
  if (RENODX_TONE_MAP_TYPE == 0.f) return untonemapped;
  renodx::color::grade::Config config = renodx::color::grade::config::Create();
  config.exposure = RENODX_TONE_MAP_EXPOSURE;
  config.contrast = RENODX_TONE_MAP_CONTRAST;
  config.flare = RENODX_TONE_MAP_FLARE;
  config.shadows = RENODX_TONE_MAP_SHADOWS;
  config.highlights = RENODX_TONE_MAP_HIGHLIGHTS;

  // PsychoV grades in its own LMS domain, so these sliders are passed to it in DisplayMap instead.
  float3 outputColor = untonemapped;
  if (RENODX_TONE_MAP_TYPE != 2.f) {
    float y = renodx::color::y::from::BT709(untonemapped);
    outputColor = ApplyExposureContrastFlareHighlightsShadowsByLuminance(untonemapped, y, config);
  }
  outputColor = ApplyHDRBoost(outputColor, CUSTOM_HDR_BOOST, 1, 0.04f);
  //outputColor = ApplyPerChannelBlowoutHueShift(outputColor);
  return outputColor;
}

float3 PostTonemapSliders(float3 hdr_color) {
  if (RENODX_TONE_MAP_TYPE == 2.f) return hdr_color;
  renodx::color::grade::Config config = renodx::color::grade::config::Create();
  config.saturation = RENODX_TONE_MAP_SATURATION;
  config.blowout = RENODX_TONE_MAP_HIGHLIGHT_SATURATION;
  config.dechroma = RENODX_TONE_MAP_BLOWOUT;
  config.blowout = -1.f * (RENODX_TONE_MAP_HIGHLIGHT_SATURATION - 1.f);

  float y = renodx::color::y::from::BT709(hdr_color);
  return ApplySaturationBlowoutHighlightSaturation(hdr_color, y, config);
}

float3 ApplyGamutExpansion(float3 color) {
  if (CUSTOM_GAMUT_EXPANSION_TYPE == 0.f || CUSTOM_GAMUT_EXPANSION == 0.f || RENODX_SWAP_CHAIN_OUTPUT_PRESET == 0.f) return color;

  float3 source_oklab = renodx::color::oklab::from::BT709(color);
  float source_chroma = length(source_oklab.yz);
  // Leaves near-black colors untouched so dark noise and banding are not saturated.
  float lightness_weight = 1.f - exp(-4.f * source_oklab.x * source_oklab.x);

  if (CUSTOM_GAMUT_EXPANSION_TYPE == 1.f) {  // OKLab Chroma (ffxiv)
    float chroma_weight = 1.f - exp(-4.f * source_chroma);
    float3 expanded_oklab = float3(source_oklab.x, source_oklab.yz * (1.f + chroma_weight * lightness_weight * CUSTOM_GAMUT_EXPANSION));
    float3 expanded_ap1 = max(0, renodx::color::ap1::from::BT709(renodx::color::bt709::from::OkLab(expanded_oklab)));
    return renodx::color::bt709::from::AP1(expanded_ap1);
  }

  // Boundary Mapped: reading the BT.709 values as BT.2020 primaries moves the BT.709 edge onto the
  // BT.2020 edge. Only that target's chroma is used; source hue and luminance are kept.
  float max_channel = renodx::math::Max(color);
  if (max_channel <= 0.f) return color;
  float bt709_saturation = saturate(1.f - renodx::math::Min(color) / max_channel);

  float3 target_oklab = renodx::color::oklab::from::BT709(renodx::color::bt709::from::BT2020(color));
  float chroma_scale = renodx::math::DivideSafe(length(target_oklab.yz), source_chroma, 1.f);
  float3 target = renodx::color::bt709::from::OkLab(float3(source_oklab.x, source_oklab.yz * chroma_scale));
  target = renodx::color::correct::Luminance(target, renodx::color::y::from::BT709(target), renodx::color::y::from::BT709(color));

  // Caps the blend where the first BT.2020 channel reaches zero, so the result stays in gamut without clipping.
  float3 source_bt2020 = renodx::color::bt2020::from::BT709(color);
  float3 target_bt2020 = renodx::color::bt2020::from::BT709(target);
  float3 channel_limit = renodx::math::Select(
      target_bt2020 < 0.f,
      renodx::math::DivideSafe(source_bt2020, source_bt2020 - target_bt2020, 1.f.xxx),
      1.f.xxx);
  float blend = CUSTOM_GAMUT_EXPANSION * pow(bt709_saturation, CUSTOM_GAMUT_EXPANSION_FALLOFF) * lightness_weight;
  blend = min(blend, saturate(renodx::math::Min(channel_limit)));

  return lerp(color, target, blend);
}

float3 DisplayMap(float3 color) {
  renodx::draw::Config config = renodx::draw::BuildConfig();  // Pulls config values
  float tonemap_peak = 1.f;
  if (RENODX_SWAP_CHAIN_OUTPUT_PRESET != 0.f) {
    float peak_nits = config.peak_white_nits / renodx::color::srgb::REFERENCE_WHITE;              // Normalizes peak
    float diffuse_white_nits = config.diffuse_white_nits / renodx::color::srgb::REFERENCE_WHITE;  // Normalizes game brightness
    tonemap_peak = peak_nits / diffuse_white_nits;
  }

   if (config.gamma_correction > 0.f) {
     tonemap_peak = renodx::color::correct::GammaSafe(tonemap_peak, config.gamma_correction > 0.f, abs(RENODX_GAMMA_CORRECTION) == 1.f ? 2.2f : 2.4f);
   }

   if (RENODX_TONE_MAP_TYPE == 2.f) {
     return renodx::tonemap::psychov::custom_psychotm_test31(
         color,
         tonemap_peak,                          // peak_value
         RENODX_TONE_MAP_EXPOSURE,              // exposure
         RENODX_TONE_MAP_HIGHLIGHTS,            // highlights
         RENODX_TONE_MAP_SHADOWS,               // shadows
         RENODX_TONE_MAP_CONTRAST,              // contrast
         RENODX_TONE_MAP_FLARE,                 // flare
         1.f,                                   // highlight_contrast
         1.f,                                   // shadow_contrast
         RENODX_TONE_MAP_SATURATION,            // purity_scale
         RENODX_TONE_MAP_HIGHLIGHT_SATURATION,  // highlight_saturation
         RENODX_TONE_MAP_BLOWOUT,               // dechroma
         0.18f.xxx,                             // current_adaptive_state_bt709
         0.18f.xxx,                             // current_background_state_bt709
         0.f,                                   // sdr_eotf_emulation (handled by gamma correction above)
         1.f,                                   // gamut_compression
         RENODX_SWAP_CHAIN_OUTPUT_PRESET == 0.f
             ? renodx::tonemap::psychov::CUSTOM_PSYCHO31_TARGET_GAMUT_BT709
             : renodx::tonemap::psychov::CUSTOM_PSYCHO31_TARGET_GAMUT_BT2020,  // gamut_compression_mode
         1.5f);                                 // compression
   }

   color = max(0, renodx::color::bt2020::from::BT709(color));

   float3 outputColor = color;
   if (RENODX_TONE_MAP_TYPE == 1.f) {
     if (RENODX_SWAP_CHAIN_OUTPUT_PRESET != 0.f) {
       outputColor = renodx::tonemap::neutwo::MaxChannel(color, tonemap_peak);
     } else {
       outputColor = renodx::tonemap::neutwo::PerChannel(color, tonemap_peak);
     }
  }

  outputColor = renodx::color::bt709::from::BT2020(outputColor);

  return outputColor;
}

float3 ApplyRenoDXPostProcessing(float3 color, float2 TEXCOORD) {
  float3 outputColor = color;
  outputColor = renodx::effects::ApplyFilmGrain(
      outputColor,
      float2(TEXCOORD.x, TEXCOORD.y),
      CUSTOM_RANDOM,
      CUSTOM_FILM_GRAIN_STRENGTH * 0.03f);
  return outputColor;
}

float3 CustomTonemap(float3 untonemapped, float2 TEXCOORD) {
  if (RENODX_TONE_MAP_TYPE == 0) {
    return renodx::draw::RenderIntermediatePass(saturate(untonemapped));
  }
  untonemapped = PreTonemapSliders(untonemapped);

  // float white_clip = RENODX_TONE_MAP_WHITE_CLIP;
  // white_clip = PreTonemapSliders(white_clip).x;
  // white_clip = min(500.f, max(white_clip, RENODX_TONE_MAP_WHITE_CLIP));

  untonemapped = ApplyPerChannelBlowoutHueShiftHueClip(untonemapped, 0.75f);
  float3 tonemapped = DisplayMap(untonemapped);
  tonemapped = PostTonemapSliders(tonemapped);
  tonemapped = ApplyGamutExpansion(tonemapped);
  tonemapped = ApplyRenoDXPostProcessing(tonemapped, TEXCOORD);
  return renodx::draw::RenderIntermediatePass(tonemapped);
}