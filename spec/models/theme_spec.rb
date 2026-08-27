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
end
