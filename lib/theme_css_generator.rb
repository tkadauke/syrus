# frozen_string_literal: true

# Compiles built-in Theme rows (EPIC-273) into `[data-theme]`-scoped CSS
# custom-property blocks. Run via `bin/generate-theme-css` after seeding or
# editing db/seeds/themes.rb. `spec/lib/theme_css_generator_spec.rb`
# re-renders this and diffs against the checked-in generated file to catch
# drift.
#
# Selectors are `:root[data-theme="slug"]` / `:root[data-theme="slug"].dark`
# rather than the bare `[data-theme="slug"]` form — CSS requires @import to
# precede all other rules in application.css, so this file's rules are
# necessarily imported *before* the plain `:root`/`.dark` fallback block
# declared later in that file. Adding `:root` to the selector raises its
# specificity above the bare `:root`/`.dark` fallback, so the compiled
# per-theme values win the cascade whenever `data-theme` is set, regardless
# of import order.
module ThemeCssGenerator
  ROOT = File.expand_path("..", __dir__)
  OUTPUT_PATH = File.join(ROOT, "app/assets/tailwind/generated/themes.generated.css")

  def self.css_for(themes)
    lines = header_lines
    themes.each { |theme| lines.concat(theme_lines(theme)) }
    "#{lines.join("\n")}\n"
  end

  def self.generate!(themes: Theme.where(built_in: true).order(:slug))
    File.write(OUTPUT_PATH, css_for(themes))
    OUTPUT_PATH
  end

  def self.header_lines
    [
      "/* GENERATED FILE. Do not edit by hand.",
      " * Source: built-in Theme rows, seeded from db/seeds/themes.rb",
      " * Regenerate with: bin/generate-theme-css",
      " */"
    ]
  end

  def self.theme_lines(theme)
    [
      *mode_block(theme, "light", %(:root[data-theme="#{theme.slug}"])),
      "",
      *mode_block(theme, "dark", %(:root[data-theme="#{theme.slug}"].dark)),
      ""
    ]
  end

  def self.mode_block(theme, mode, selector)
    mode_tokens = theme.tokens.fetch(mode)
    lines = ["#{selector} {"]
    Theme::TOKEN_KEYS.each { |key| lines << "  --color-#{key}: #{mode_tokens.fetch(key)};" }
    lines << "}"
    lines
  end
end
