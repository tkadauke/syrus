# Plain-Ruby WCAG 2.x relative-luminance contrast ratio (no gem needed --
# see https://www.w3.org/TR/WCAG21/#dfn-relative-luminance /
# https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio). Used by Theme#contrast_issues
# to flag illegible token pairings before a theme is installed.
module ColorContrast
  AA_NORMAL_TEXT_RATIO = 4.5

  module_function

  def ratio(hex_a, hex_b)
    luminance_a = relative_luminance(hex_a)
    luminance_b = relative_luminance(hex_b)
    lighter, darker = [ luminance_a, luminance_b ].max, [ luminance_a, luminance_b ].min
    (lighter + 0.05) / (darker + 0.05)
  end

  def relative_luminance(hex)
    r, g, b = rgb(hex).map { |channel| linearize(channel) }
    (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
  end

  # Approximates a tinted "status pill" background (e.g. Tailwind's
  # `bg-emerald-50` / `dark:bg-emerald-950/50` that `StatusPill`'s `TonePill`
  # renders behind a status tone) by alpha-blending the tone color over the
  # theme's own `surface` -- there's no per-tone Tailwind-style shade scale
  # to draw an exact "50"/"950" stop from for an arbitrary user-defined
  # theme, so this is a documented approximation, not a literal match.
  def blend(base_hex, tint_hex, alpha)
    base = rgb(base_hex)
    tint = rgb(tint_hex)
    blended = base.zip(tint).map { |base_channel, tint_channel| ((base_channel * (1 - alpha)) + (tint_channel * alpha)).round.clamp(0, 255) }
    format("#%02x%02x%02x", *blended)
  end

  def rgb(hex)
    normalized = hex.to_s.delete_prefix("#")
    normalized.scan(/../).map { |part| part.to_i(16) }
  end

  def linearize(channel)
    c = channel / 255.0
    c <= 0.03928 ? c / 12.92 : (((c + 0.055) / 1.055) ** 2.4)
  end
end
