# Checked-in source of truth for the built-in Theme rows (EPIC-273 job 1).
# Values are copied verbatim from the Epic description; do not re-derive
# them. `db/seeds.rb` calls `Seeds::Themes.seed!` to upsert these into the
# `themes` table, and `bin/generate-theme-css` compiles the resulting
# `built_in: true` rows into scoped CSS custom-property blocks.
#
# `on-brand` (the 13th token, alongside the 12 declared in
# app/assets/tailwind/application.css) resolves this job's flagged open
# question: Button.tsx's primary variant hardcoded `text-white` on top of
# `brand`, which is illegible against Ocean/Forest's lighter dark-mode
# `brand` values. Terracotta's `brand` stays dark in both modes, so it
# keeps white in both; Ocean/Forest use a near-black, theme-matched dark
# value (their own dark `surface`) for `on-brand` in dark mode only. See
# Button.tsx and application.css for the consuming side.
module Seeds
  module Themes
    DEFINITIONS = [
      {
        slug: "terracotta",
        name: "Terracotta",
        tokens: {
          "light" => {
            "brand" => "#b6492e",
            "brand-emphasis" => "#973b25",
            "surface" => "#ffffff",
            "surface-raised" => "#f9fafb",
            "border" => "#e5e7eb",
            "text-primary" => "#111827",
            "text-secondary" => "#6b7280",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#374151",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#b6492e",
            "brand-emphasis" => "#dba28b",
            "surface" => "#111827",
            "surface-raised" => "#1f2937",
            "border" => "#374151",
            "text-primary" => "#f3f4f6",
            "text-secondary" => "#9ca3af",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#e5e7eb",
            "on-brand" => "#ffffff"
          }
        }
      },
      {
        slug: "ocean",
        name: "Ocean",
        tokens: {
          "light" => {
            "brand" => "#1d6fa5",
            "brand-emphasis" => "#155a87",
            "surface" => "#ffffff",
            "surface-raised" => "#f4f9fb",
            "border" => "#dbe6ec",
            "text-primary" => "#0f1b24",
            "text-secondary" => "#5b7280",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#0e7490",
            "neutral" => "#3f4b54",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#4db3e8",
            "brand-emphasis" => "#8ed6f2",
            "surface" => "#0b1620",
            "surface-raised" => "#142430",
            "border" => "#24404d",
            "text-primary" => "#eaf3f8",
            "text-secondary" => "#9db2bd",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#67e8f9",
            "neutral" => "#cbd5df",
            "on-brand" => "#0b1620"
          }
        }
      },
      {
        slug: "forest",
        name: "Forest",
        tokens: {
          "light" => {
            "brand" => "#2f7d46",
            "brand-emphasis" => "#1f5c33",
            "surface" => "#ffffff",
            "surface-raised" => "#f6f9f6",
            "border" => "#dde8de",
            "text-primary" => "#16241b",
            "text-secondary" => "#5b6b5e",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#41504a",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#5fbf7d",
            "brand-emphasis" => "#a6e0b5",
            "surface" => "#0d1811",
            "surface-raised" => "#16261c",
            "border" => "#2c3f31",
            "text-primary" => "#eef5ef",
            "text-secondary" => "#a3b5a8",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#cdd9d1",
            "on-brand" => "#0d1811"
          }
        }
      }
    ].freeze

    def self.seed!
      DEFINITIONS.each do |definition|
        theme = Theme.find_or_initialize_by(slug: definition.fetch(:slug))
        theme.assign_attributes(
          name: definition.fetch(:name),
          built_in: true,
          owner_user_id: nil,
          tokens: definition.fetch(:tokens)
        )
        theme.save!
      end
    end
  end
end
