require "rails_helper"
require Rails.root.join("db/seeds/themes")

RSpec.describe Seeds::Themes do
  BUILT_IN_SLUGS = %w[
    terracotta ocean forest sunset lavender slate rose amber midnight
    mint plum sand sky crimson moss coral steel violet console
  ].freeze

  describe ".seed!" do
    it "creates the 19 built-in themes with valid token shapes" do
      expect { described_class.seed! }.to change(Theme, :count).by(19)

      BUILT_IN_SLUGS.each do |slug|
        theme = Theme.find_by(slug: slug)
        expect(theme).to be_present
        expect(theme.built_in).to be true
        expect(theme.owner_user_id).to be_nil
        expect(theme).to be_valid
      end
    end

    it "passes WCAG AA contrast validation for every built-in theme" do
      described_class.seed!

      BUILT_IN_SLUGS.each do |slug|
        theme = Theme.find_by!(slug: slug)
        expect(theme.contrast_issues).to eq([]), "#{slug}: #{theme.contrast_issues.map { |i| i[:message] }.join('; ')}"
      end
    end

    it "is idempotent — reseeding does not duplicate or error" do
      described_class.seed!
      expect { described_class.seed! }.not_to change(Theme, :count)
    end

    it "updates an existing row's tokens instead of duplicating on slug" do
      described_class.seed!
      terracotta = Theme.find_by!(slug: "terracotta")
      terracotta.update!(name: "Stale Name")

      described_class.seed!

      expect(Theme.where(slug: "terracotta").count).to eq(1)
      expect(terracotta.reload.name).to eq("Terracotta")
    end

    it "matches the exact verbatim values from the existing application.css schema for terracotta" do
      described_class.seed!
      terracotta = Theme.find_by!(slug: "terracotta")

      expect(terracotta.tokens["light"]["brand"]).to eq("#b6492e")
      expect(terracotta.tokens["light"]["surface"]).to eq("#ffffff")
      expect(terracotta.tokens["dark"]["brand-emphasis"]).to eq("#dba28b")
      expect(terracotta.tokens["dark"]["neutral"]).to eq("#e5e7eb")
    end

    it "seeds Console with non-default extended (non-color) tokens, proving the model beyond color" do
      described_class.seed!
      console = Theme.find_by!(slug: "console")

      Theme::EXTENDED_TOKEN_GROUPS.each_key do |group|
        expect(console.tokens[group]).to be_present, "expected console to store an explicit '#{group}' override"
        expect(console.tokens[group]).not_to eq(Theme::DEFAULT_EXTENDED_TOKENS.fetch(group))
      end

      expect(console.tokens_with_defaults["shape"]["radius-control"]).to eq("0px")
      expect(console.tokens_with_defaults["typography"]["font-sans"]).to include("monospace")
    end

    it "carries a definition's extended token groups through unchanged alongside the syntax-token-augmented light/dark hashes" do
      definition = described_class::DEFINITIONS.find { |d| d.fetch(:slug) == "console" }

      expect(definition.fetch(:tokens)["shape"]).to eq(described_class::BASE_DEFINITIONS.find { |d| d.fetch(:slug) == "console" }.fetch(:tokens)["shape"])
      expect(definition.fetch(:tokens)["light"]).to include("token-keyword" => definition.fetch(:tokens)["light"].fetch("brand-emphasis"))
    end

    it "does not add spurious extended token groups to a definition that never set any" do
      terracotta = described_class::DEFINITIONS.find { |d| d.fetch(:slug) == "terracotta" }

      expect(terracotta.fetch(:tokens).keys).to contain_exactly("light", "dark")
    end
  end
end
