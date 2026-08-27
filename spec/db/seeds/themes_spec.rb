require "rails_helper"
require Rails.root.join("db/seeds/themes")

RSpec.describe Seeds::Themes do
  describe ".seed!" do
    it "creates the 3 built-in themes with valid token shapes" do
      expect { described_class.seed! }.to change(Theme, :count).by(3)

      %w[terracotta ocean forest].each do |slug|
        theme = Theme.find_by(slug: slug)
        expect(theme).to be_present
        expect(theme.built_in).to be true
        expect(theme.owner_user_id).to be_nil
        expect(theme).to be_valid
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
  end
end
