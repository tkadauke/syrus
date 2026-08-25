# frozen_string_literal: true

require "json"

# Single source of truth for the terracotta brand scale
# (`config/design_tokens/terracotta.json`). `config/tailwind.config.js`
# requires that JSON file directly; desktop's Vite/Lightning CSS pipeline
# can't require JSON, so `bin/generate-brand-tokens` uses this module to
# render the equivalent `@theme` partial consumed by `desktop/src/styles.css`.
# `spec/desktop/brand_palette_spec.rb` re-renders it and diffs against the
# checked-in file to catch drift.
module DesignTokens
  module TerracottaTheme
    ROOT = File.expand_path("../..", __dir__)
    SOURCE_PATH = File.join(ROOT, "config/design_tokens/terracotta.json")
    DESKTOP_OUTPUT_PATH = File.join(ROOT, "desktop/src/styles/brand-tokens.generated.css")

    STEPS = %w[50 100 200 300 400 500 600 700 800 900 950].freeze

    def self.scale
      JSON.parse(File.read(SOURCE_PATH))
    end

    # Tailwind's default `blue` scale is remapped onto terracotta so legacy
    # `*-blue-*` utilities render the brand accent too (see
    # config/tailwind.config.js and CLAUDE.md's "Brand palette" convention).
    def self.desktop_css
      scale_values = scale
      lines = [
        "/* GENERATED FILE. Do not edit by hand.",
        " * Source: config/design_tokens/terracotta.json",
        " * Regenerate with: bin/generate-brand-tokens",
        " */",
        "@theme {"
      ]
      STEPS.each { |step| lines << "  --color-terracotta-#{step}: #{scale_values.fetch(step)};" }
      STEPS.each { |step| lines << "  --color-blue-#{step}: #{scale_values.fetch(step)};" }
      lines << "}"
      "#{lines.join("\n")}\n"
    end
  end
end
