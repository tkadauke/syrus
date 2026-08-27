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
    it "returns id, slug, name, built_in, and tokens" do
      t = theme(built_in: true)

      expect(t.public_payload).to eq(
        id: t.id,
        slug: t.slug,
        name: t.name,
        built_in: true,
        tokens: t.tokens
      )
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
  end
end
