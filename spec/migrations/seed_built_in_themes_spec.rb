require "rails_helper"
require Rails.root.join("db/migrate/20260828154548_seed_built_in_themes")

RSpec.describe SeedBuiltInThemes, :ci_only do
  let(:migration) { described_class.new }

  it "seeds all 18 built-in Theme rows on an existing database" do
    expect(Theme.where(built_in: true).count).to eq(0)

    migration.up

    expect(Theme.where(built_in: true).count).to eq(18)
    expect(Theme.find_by(slug: "terracotta")).to be_present
  end

  it "backfills users with no color_theme_id to the built-in Terracotta theme" do
    user = Factories.user(color_theme_id: nil)

    migration.up

    expect(user.reload.color_theme_id).to eq(Theme.terracotta.id)
  end

  it "does not override a user's existing color_theme_id" do
    migration.up
    custom = Factories.theme(built_in: false)
    user = Factories.user(color_theme: custom)

    migration.up

    expect(user.reload.color_theme_id).to eq(custom.id)
  end

  it "is idempotent — re-running does not duplicate or error" do
    migration.up

    expect { migration.up }.not_to change(Theme, :count)
  end
end
