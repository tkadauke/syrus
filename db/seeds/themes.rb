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
      },
      {
        slug: "sunset",
        name: "Sunset",
        tokens: {
          "light" => {
            "brand" => "#d9662c",
            "brand-emphasis" => "#b34f1f",
            "surface" => "#ffffff",
            "surface-raised" => "#fdf6f0",
            "border" => "#f0ddd0",
            "text-primary" => "#241108",
            "text-secondary" => "#7a5a48",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b5548",
            "on-brand" => "#241108"
          },
          "dark" => {
            "brand" => "#f0894f",
            "brand-emphasis" => "#f7b487",
            "surface" => "#201007",
            "surface-raised" => "#2b1810",
            "border" => "#4a3122",
            "text-primary" => "#fbeee3",
            "text-secondary" => "#cba98f",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#d8c2ae",
            "on-brand" => "#2b1305"
          }
        }
      },
      {
        slug: "lavender",
        name: "Lavender",
        tokens: {
          "light" => {
            "brand" => "#7c5cbf",
            "brand-emphasis" => "#62469b",
            "surface" => "#ffffff",
            "surface-raised" => "#f7f4fc",
            "border" => "#e3dcf3",
            "text-primary" => "#201a2e",
            "text-secondary" => "#6c6280",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#5b5470",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#a98cec",
            "brand-emphasis" => "#cbb6f5",
            "surface" => "#17101f",
            "surface-raised" => "#221a2e",
            "border" => "#392c4d",
            "text-primary" => "#f1ecfa",
            "text-secondary" => "#b8abd1",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#c6b9dc",
            "on-brand" => "#1c1530"
          }
        }
      },
      {
        slug: "slate",
        name: "Slate",
        tokens: {
          "light" => {
            "brand" => "#46647d",
            "brand-emphasis" => "#364f63",
            "surface" => "#ffffff",
            "surface-raised" => "#f5f7f9",
            "border" => "#dee5ea",
            "text-primary" => "#131c22",
            "text-secondary" => "#5c6f7a",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#4d5c66",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#7ea3bd",
            "brand-emphasis" => "#a9c6da",
            "surface" => "#0d1418",
            "surface-raised" => "#17222a",
            "border" => "#2c3d47",
            "text-primary" => "#eaf1f5",
            "text-secondary" => "#a1b6c1",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#b6c6cf",
            "on-brand" => "#0e161b"
          }
        }
      },
      {
        slug: "rose",
        name: "Rose",
        tokens: {
          "light" => {
            "brand" => "#c2477a",
            "brand-emphasis" => "#9c3661",
            "surface" => "#ffffff",
            "surface-raised" => "#fdf4f8",
            "border" => "#f2dbe6",
            "text-primary" => "#250f18",
            "text-secondary" => "#7d5364",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b4d59",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#e37fac",
            "brand-emphasis" => "#eeaac8",
            "surface" => "#1f0f16",
            "surface-raised" => "#2b1720",
            "border" => "#4a2c39",
            "text-primary" => "#fbe9f0",
            "text-secondary" => "#d3aabd",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#d8bcc9",
            "on-brand" => "#290f1c"
          }
        }
      },
      {
        slug: "amber",
        name: "Amber",
        tokens: {
          "light" => {
            "brand" => "#b8811c",
            "brand-emphasis" => "#916712",
            "surface" => "#ffffff",
            "surface-raised" => "#fbf6ea",
            "border" => "#ecdfc0",
            "text-primary" => "#201705",
            "text-secondary" => "#7a6839",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b5d3a",
            "on-brand" => "#1c1200"
          },
          "dark" => {
            "brand" => "#e0ac47",
            "brand-emphasis" => "#edc57e",
            "surface" => "#1c1607",
            "surface-raised" => "#292110",
            "border" => "#493c1e",
            "text-primary" => "#f7edd8",
            "text-secondary" => "#d0bd8e",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#d3c39c",
            "on-brand" => "#1c1200"
          }
        }
      },
      {
        slug: "midnight",
        name: "Midnight",
        tokens: {
          "light" => {
            "brand" => "#3949ab",
            "brand-emphasis" => "#2c3789",
            "surface" => "#ffffff",
            "surface-raised" => "#f4f5fb",
            "border" => "#dcdfef",
            "text-primary" => "#14172b",
            "text-secondary" => "#575e7d",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#0e7490",
            "neutral" => "#4b5170",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#7986cb",
            "brand-emphasis" => "#aab2e0",
            "surface" => "#0c0e1c",
            "surface-raised" => "#161a2c",
            "border" => "#2b3050",
            "text-primary" => "#e9eaf6",
            "text-secondary" => "#a6acce",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#67e8f9",
            "neutral" => "#b6bade",
            "on-brand" => "#101425"
          }
        }
      },
      {
        slug: "mint",
        name: "Mint",
        tokens: {
          "light" => {
            "brand" => "#1f9e83",
            "brand-emphasis" => "#187c67",
            "surface" => "#ffffff",
            "surface-raised" => "#f1faf7",
            "border" => "#d3ece5",
            "text-primary" => "#0c211c",
            "text-secondary" => "#4e7a70",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#47665f",
            "on-brand" => "#0c211c"
          },
          "dark" => {
            "brand" => "#4fd0b2",
            "brand-emphasis" => "#8fe4cf",
            "surface" => "#071815",
            "surface-raised" => "#0f2420",
            "border" => "#1f3d36",
            "text-primary" => "#e4faf4",
            "text-secondary" => "#9fcdc0",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#a9cec5",
            "on-brand" => "#08211b"
          }
        }
      },
      {
        slug: "plum",
        name: "Plum",
        tokens: {
          "light" => {
            "brand" => "#8a3f6b",
            "brand-emphasis" => "#6c3054",
            "surface" => "#ffffff",
            "surface-raised" => "#faf3f7",
            "border" => "#ecdae4",
            "text-primary" => "#211018",
            "text-secondary" => "#6f5262",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#5f4b57",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#c179a3",
            "brand-emphasis" => "#dba7c5",
            "surface" => "#1a0f16",
            "surface-raised" => "#261722",
            "border" => "#422b3a",
            "text-primary" => "#f6e9f1",
            "text-secondary" => "#ccabbe",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#cbb3c1",
            "on-brand" => "#22101c"
          }
        }
      },
      {
        slug: "sand",
        name: "Sand",
        tokens: {
          "light" => {
            "brand" => "#a97a4a",
            "brand-emphasis" => "#86603a",
            "surface" => "#fffdfa",
            "surface-raised" => "#f7f0e5",
            "border" => "#e8dcc8",
            "text-primary" => "#241a0d",
            "text-secondary" => "#7a6a52",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b5d47",
            "on-brand" => "#241a0d"
          },
          "dark" => {
            "brand" => "#cf9e6c",
            "brand-emphasis" => "#e0bb92",
            "surface" => "#1c1610",
            "surface-raised" => "#29211a",
            "border" => "#493c2c",
            "text-primary" => "#f4ead9",
            "text-secondary" => "#cab89e",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#cebda2",
            "on-brand" => "#241a0d"
          }
        }
      },
      {
        slug: "sky",
        name: "Sky",
        tokens: {
          "light" => {
            "brand" => "#2a93c9",
            "brand-emphasis" => "#1f739e",
            "surface" => "#ffffff",
            "surface-raised" => "#f2fafd",
            "border" => "#d7ecf5",
            "text-primary" => "#0e1f27",
            "text-secondary" => "#4c788a",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#0e7490",
            "neutral" => "#47616c",
            "on-brand" => "#0e1f27"
          },
          "dark" => {
            "brand" => "#6cc4ee",
            "brand-emphasis" => "#a4dcf6",
            "surface" => "#081419",
            "surface-raised" => "#10222a",
            "border" => "#223c47",
            "text-primary" => "#e6f5fb",
            "text-secondary" => "#9dc2d3",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#67e8f9",
            "neutral" => "#a7c2cd",
            "on-brand" => "#0b1c24"
          }
        }
      },
      {
        slug: "crimson",
        name: "Crimson",
        tokens: {
          "light" => {
            "brand" => "#c0293f",
            "brand-emphasis" => "#981f31",
            "surface" => "#ffffff",
            "surface-raised" => "#fdf3f4",
            "border" => "#f2d9dc",
            "text-primary" => "#240b0e",
            "text-secondary" => "#7d4d53",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b474c",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#e56b7c",
            "brand-emphasis" => "#f0a0ac",
            "surface" => "#1e0d0f",
            "surface-raised" => "#2b1417",
            "border" => "#4a2429",
            "text-primary" => "#fbe8ea",
            "text-secondary" => "#d3a7ad",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#d6b3b7",
            "on-brand" => "#260c0f"
          }
        }
      },
      {
        slug: "moss",
        name: "Moss",
        tokens: {
          "light" => {
            "brand" => "#6f7d3c",
            "brand-emphasis" => "#59642f",
            "surface" => "#ffffff",
            "surface-raised" => "#f6f8ee",
            "border" => "#e2e6cd",
            "text-primary" => "#191d0b",
            "text-secondary" => "#626b48",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#565c3f",
            "on-brand" => "#000000"
          },
          "dark" => {
            "brand" => "#a3b567",
            "brand-emphasis" => "#c2d193",
            "surface" => "#14160a",
            "surface-raised" => "#1f2312",
            "border" => "#363c1f",
            "text-primary" => "#eef1e0",
            "text-secondary" => "#bcc59b",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#c4cca3",
            "on-brand" => "#191d0b"
          }
        }
      },
      {
        slug: "coral",
        name: "Coral",
        tokens: {
          "light" => {
            "brand" => "#e0654f",
            "brand-emphasis" => "#b74d3a",
            "surface" => "#ffffff",
            "surface-raised" => "#fdf4f1",
            "border" => "#f2ddd6",
            "text-primary" => "#260f0a",
            "text-secondary" => "#825a4e",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#6b4d43",
            "on-brand" => "#260f0a"
          },
          "dark" => {
            "brand" => "#f29a86",
            "brand-emphasis" => "#f7bfae",
            "surface" => "#1f100a",
            "surface-raised" => "#2b1911",
            "border" => "#4a2c20",
            "text-primary" => "#fbeae4",
            "text-secondary" => "#d6b0a2",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#d9b8ab",
            "on-brand" => "#2a1109"
          }
        }
      },
      {
        slug: "steel",
        name: "Steel",
        tokens: {
          "light" => {
            "brand" => "#4a5568",
            "brand-emphasis" => "#37404e",
            "surface" => "#ffffff",
            "surface-raised" => "#f5f6f8",
            "border" => "#dfe2e7",
            "text-primary" => "#14171c",
            "text-secondary" => "#5c6472",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#4d5560",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#8b96a8",
            "brand-emphasis" => "#b3bcc9",
            "surface" => "#0d0f13",
            "surface-raised" => "#181b21",
            "border" => "#2d323b",
            "text-primary" => "#e9ebee",
            "text-secondary" => "#a5adba",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#b7bfc9",
            "on-brand" => "#0f1216"
          }
        }
      },
      {
        slug: "violet",
        name: "Violet",
        tokens: {
          "light" => {
            "brand" => "#6d3fc9",
            "brand-emphasis" => "#5530a3",
            "surface" => "#ffffff",
            "surface-raised" => "#f6f2fc",
            "border" => "#e2d7f5",
            "text-primary" => "#190d2b",
            "text-secondary" => "#5f5477",
            "success" => "#047857",
            "warning" => "#b45309",
            "danger" => "#b91c1c",
            "info" => "#1d4ed8",
            "neutral" => "#524a6b",
            "on-brand" => "#ffffff"
          },
          "dark" => {
            "brand" => "#a986ed",
            "brand-emphasis" => "#c9b1f5",
            "surface" => "#130b1f",
            "surface-raised" => "#1e142d",
            "border" => "#362a4d",
            "text-primary" => "#ede7fa",
            "text-secondary" => "#bcaed6",
            "success" => "#a7f3d0",
            "warning" => "#fde68a",
            "danger" => "#fecaca",
            "info" => "#bfdbfe",
            "neutral" => "#beb1d6",
            "on-brand" => "#190d2b"
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
