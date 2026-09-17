require "rails_helper"

RSpec.describe Theme do
  def new_theme(**attrs)
    Theme.new({
      name: "Test Theme",
      slug: "test-theme-#{SecureRandom.hex(4)}",
      built_in: false,
      tokens: theme_tokens
    }.merge(attrs))
  end

  describe "validations" do
    it "is valid with a well-shaped tokens hash" do
      expect(new_theme).to be_valid
    end

    it "requires a name" do
      expect(new_theme(name: nil)).not_to be_valid
    end

    it "requires a unique slug" do
      theme(slug: "duplicate-slug")
      expect(new_theme(slug: "duplicate-slug")).not_to be_valid
    end

    it "rejects slugs with characters outside lowercase letters, numbers, and hyphens" do
      expect(new_theme(slug: "Not Valid!")).not_to be_valid
    end

    it "rejects a built-in theme with an owner_user_id" do
      built_in = new_theme(built_in: true, owner_user_id: user.id)
      expect(built_in).not_to be_valid
      expect(built_in.errors[:owner_user_id]).to be_present
    end

    it "allows a non-built-in theme to have an owner" do
      owned = new_theme(built_in: false, owner_user: user)
      expect(owned).to be_valid
    end

    it "requires tokens to be a hash" do
      invalid = new_theme(tokens: nil)
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens]).to be_present
    end

    it "requires both light and dark token hashes" do
      invalid = new_theme(tokens: { "light" => theme_tokens["light"] })
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens].join).to include("dark")
    end

    it "requires every token key to be present in each mode" do
      incomplete = theme_tokens["light"].except("brand")
      invalid = new_theme(tokens: { "light" => incomplete, "dark" => theme_tokens["dark"] })
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens].join).to include("brand")
    end

    it "does not require Theme::SYNTAX_TOKEN_KEYS to be present" do
      # theme_tokens only fills in Theme::TOKEN_KEYS -- a custom/agent-authored
      # theme without syntax-highlighting tokens must still be valid; it
      # renders via the --shiki-* fallbacks in application.css instead.
      expect(new_theme).to be_valid
      expect(Theme::SYNTAX_TOKEN_KEYS & theme_tokens["light"].keys).to be_empty
    end

    it "is valid with a color-only tokens hash that predates the shape/density/typography/spacing/shadow expansion" do
      # theme_tokens has no "shape"/"shadow"/"spacing"/"density"/"typography"
      # keys at all -- the exact shape every stored theme had before this
      # token expansion landed.
      old_theme = new_theme(tokens: theme_tokens)
      expect(old_theme).to be_valid
      Theme::EXTENDED_TOKEN_GROUPS.each_key { |group| expect(theme_tokens).not_to have_key(group) }
    end

    it "is valid when an extended group is only partially specified" do
      partial = theme_tokens.merge("typography" => { "font-sans" => "Custom, sans-serif" })
      expect(new_theme(tokens: partial)).to be_valid
    end

    it "rejects an extended group that is not a hash" do
      invalid = new_theme(tokens: theme_tokens.merge("shape" => "0.5rem"))
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens].join).to include("shape must be a hash")
    end

    it "rejects an extended group with an unknown key" do
      invalid = new_theme(tokens: theme_tokens.merge("shape" => { "radius-huge" => "2rem" }))
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens].join).to include("shape has unknown keys: radius-huge")
    end

    it "rejects an extended group with a non-string value" do
      invalid = new_theme(tokens: theme_tokens.merge("spacing" => { "space-section" => 16 }))
      expect(invalid).not_to be_valid
      expect(invalid.errors[:tokens].join).to include("spacing values must be strings: space-section")
    end
  end

  describe ".terracotta" do
    it "finds the built-in theme with slug=terracotta" do
      terracotta = theme(slug: "terracotta", built_in: true)
      expect(Theme.terracotta).to eq(terracotta)
    end

    it "returns nil when no terracotta theme exists" do
      expect(Theme.terracotta).to be_nil
    end
  end

  describe "associations" do
    it "nullifies dependent users' color_theme_id on destroy" do
      t = theme
      owner = user(color_theme: t)
      t.destroy!
      expect(owner.reload.color_theme_id).to be_nil
    end
  end

  describe ".selectable_by" do
    it "includes built-in themes and the given user's own themes, excluding other users' themes" do
      owner = user
      other = user
      built_in = theme(built_in: true)
      mine = theme(built_in: false, owner_user: owner)
      theirs = theme(built_in: false, owner_user: other)

      expect(Theme.selectable_by(owner)).to contain_exactly(built_in, mine)
      expect(Theme.selectable_by(owner)).not_to include(theirs)
    end
  end

  describe "#public_payload" do
    it "returns id, slug, name, built_in, and tokens with extended defaults merged in" do
      t = theme(built_in: true)

      expect(t.public_payload).to eq(
        id: t.id,
        slug: t.slug,
        name: t.name,
        built_in: true,
        position: nil,
        tokens: t.tokens_with_defaults
      )
    end

    it "backfills default shape/shadow/spacing/density/typography groups for a color-only stored theme" do
      t = theme(tokens: theme_tokens)

      payload_tokens = t.public_payload[:tokens]

      expect(payload_tokens["light"]).to eq(theme_tokens["light"])
      expect(payload_tokens["dark"]).to eq(theme_tokens["dark"])
      Theme::EXTENDED_TOKEN_GROUPS.each do |group, keys|
        expect(payload_tokens[group]).to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch(group))
        expect(payload_tokens[group].keys).to match_array(keys)
      end
    end
  end

  describe "#tokens_with_defaults" do
    it "returns tokens unchanged when tokens is not a hash" do
      expect(new_theme(tokens: nil).tokens_with_defaults).to be_nil
    end

    it "fills in the default value for a group that is present but missing some keys" do
      partial = theme_tokens.merge("shape" => { "radius-panel" => "1rem" })
      resolved = new_theme(tokens: partial).tokens_with_defaults

      expect(resolved["shape"]).to eq(
        Theme::DEFAULT_EXTENDED_TOKENS.fetch("shape").merge("radius-panel" => "1rem")
      )
    end

    it "leaves an explicitly overridden group's values untouched when fully specified" do
      overrides = { "control-height-sm" => "1.75rem", "control-height-md" => "2.25rem", "table-row-height" => "2.5rem" }
      custom = theme_tokens.merge("density" => overrides)

      expect(new_theme(tokens: custom).tokens_with_defaults["density"]).to eq(overrides)
    end
  end

  describe "#contrast_issues" do
    def legible_tokens
      {
        "light" => {
          "brand" => "#b6492e", "brand-emphasis" => "#973b25", "surface" => "#ffffff",
          "surface-raised" => "#f9fafb", "border" => "#e5e7eb", "text-primary" => "#111827",
          "text-secondary" => "#6b7280", "success" => "#047857", "warning" => "#b45309",
          "danger" => "#b91c1c", "info" => "#1d4ed8", "neutral" => "#374151", "on-brand" => "#ffffff"
        },
        "dark" => {
          "brand" => "#b6492e", "brand-emphasis" => "#dba28b", "surface" => "#111827",
          "surface-raised" => "#1f2937", "border" => "#374151", "text-primary" => "#f3f4f6",
          "text-secondary" => "#9ca3af", "success" => "#a7f3d0", "warning" => "#fde68a",
          "danger" => "#fecaca", "info" => "#bfdbfe", "neutral" => "#e5e7eb", "on-brand" => "#ffffff"
        }
      }
    end

    it "returns no issues for a legible palette (the real Terracotta values)" do
      expect(new_theme(tokens: legible_tokens).contrast_issues).to eq([])
    end

    it "flags a text token that fails WCAG AA against a surface" do
      tokens = legible_tokens
      tokens["light"]["text-secondary"] = "#f0f0f0"

      issues = new_theme(tokens: tokens).contrast_issues
      issue = issues.find { |i| i[:mode] == "light" && i[:foreground] == "text-secondary" && i[:background] == "surface" }

      expect(issue).to be_present
      expect(issue[:ratio]).to be < 4.5
      expect(issue[:required_ratio]).to eq(4.5)
      expect(issue[:message]).to include("text-secondary").and include("surface").and include("4.5")
    end

    it "flags a status tone that fails WCAG AA against its tinted background" do
      tokens = legible_tokens
      tokens["dark"]["warning"] = "#12130f"

      issues = new_theme(tokens: tokens).contrast_issues
      issue = issues.find { |i| i[:mode] == "dark" && i[:foreground] == "warning" }

      expect(issue).to be_present
      expect(issue[:ratio]).to be < 4.5
    end

    it "returns no issues when tokens aren't shaped correctly yet (validation, not contrast, owns that)" do
      expect(new_theme(tokens: nil).contrast_issues).to eq([])
      expect(new_theme(tokens: { "light" => legible_tokens["light"] }).contrast_issues).to eq([])
    end

    it "flags on-brand text that fails WCAG AA against brand (the pairing on-brand exists to protect)" do
      tokens = legible_tokens
      tokens["dark"]["brand"] = "#5fbf7d"
      tokens["dark"]["on-brand"] = "#6fcf8d"

      issues = new_theme(tokens: tokens).contrast_issues
      issue = issues.find { |i| i[:mode] == "dark" && i[:foreground] == "on-brand" && i[:background] == "brand" }

      expect(issue).to be_present
      expect(issue[:ratio]).to be < 4.5
      expect(issue[:message]).to include("on-brand").and include("brand")
    end
  end

  describe "#contrast_warning_messages" do
    def legible_tokens
      {
        "light" => {
          "brand" => "#b6492e", "brand-emphasis" => "#973b25", "surface" => "#ffffff",
          "surface-raised" => "#f9fafb", "border" => "#e5e7eb", "text-primary" => "#111827",
          "text-secondary" => "#6b7280", "success" => "#047857", "warning" => "#b45309",
          "danger" => "#b91c1c", "info" => "#1d4ed8", "neutral" => "#374151", "on-brand" => "#ffffff"
        },
        "dark" => {
          "brand" => "#b6492e", "brand-emphasis" => "#dba28b", "surface" => "#111827",
          "surface-raised" => "#1f2937", "border" => "#374151", "text-primary" => "#f3f4f6",
          "text-secondary" => "#9ca3af", "success" => "#a7f3d0", "warning" => "#fde68a",
          "danger" => "#fecaca", "info" => "#bfdbfe", "neutral" => "#e5e7eb", "on-brand" => "#ffffff"
        }
      }
    end

    it "returns the same messages as #contrast_issues for a legible palette (empty)" do
      expect(new_theme(tokens: legible_tokens).contrast_warning_messages).to eq([])
    end

    it "returns the #contrast_issues messages for a palette with a real issue" do
      tokens = legible_tokens
      tokens["light"]["text-secondary"] = "#f0f0f0"
      theme = new_theme(tokens: tokens)

      expect(theme.contrast_warning_messages).to eq(theme.contrast_issues.map { |issue| issue.fetch(:message) })
      expect(theme.contrast_warning_messages).not_to be_empty
    end

    it "rescues a malformed color value instead of raising, and logs a warning" do
      # Only a status-tone value can actually crash contrast_issues: its check
      # blends the tone color against `surface` via ColorContrast.blend, which
      # zips both colors' parsed RGB channel arrays -- a value that doesn't
      # parse into exactly 3 channels (unlike a plain ratio check) raises
      # NoMethodError deep inside that zip.
      tokens = legible_tokens
      tokens["light"]["danger"] = "abcde"
      theme = new_theme(tokens: tokens)

      expect(Rails.logger).to receive(:warn).with(/contrast_issues raised/)
      result = nil
      expect { result = theme.contrast_warning_messages }.not_to raise_error
      expect(result).to eq([])
    end
  end
end
