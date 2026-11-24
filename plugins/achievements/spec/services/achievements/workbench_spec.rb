require "rails_helper"

RSpec.describe Achievements::Workbench do
  def set_enabled(name, value)
    PluginRecord.find_or_create_by!(name: name).update!(enabled: value, disableable: true)
  end

  describe ".available? (enable/disable matrix)" do
    [
      [ true, true, true ],
      [ true, false, false ],
      [ false, true, false ],
      [ false, false, false ]
    ].each do |achievements, syrus_dev, expected|
      it "is #{expected} with achievements=#{achievements} syrus_dev=#{syrus_dev}" do
        set_enabled("achievements", achievements)
        set_enabled("syrus_dev", syrus_dev)

        expect(described_class.available?).to be(expected)
        expect(Achievements::AdminPages.admin_pages.map { |page| page[:id] }).to eq(expected ? [ "achievements.workbench" ] : [])
      end
    end

    it "leaves the runtime (collection page) untouched when only syrus_dev is disabled" do
      set_enabled("achievements", true)
      set_enabled("syrus_dev", false)
      Current.api_user = Factories.user

      expect(Achievements::SidebarPages.sidebar_pages.map { |page| page[:path] }).to eq([ "/achievements" ])
    ensure
      Current.reset
    end
  end

  it "contributes its page only under its own namespace" do
    set_enabled("achievements", true)
    set_enabled("syrus_dev", true)
    page = Achievements::AdminPages.admin_pages.first

    expect(page).to include(path: "/admin/achievements_workbench", component: "achievements/AchievementsWorkbench")
  end

  it "never lets syrus_dev reference achievements" do
    files = Dir[Rails.root.join("plugins/syrus_dev/**/*.{rb,ts,tsx,json,yml}")]
    expect(files.select { |path| File.read(path).match?(/achievement/i) }).to be_empty
  end

  describe ".catalog" do
    it "enumerates every registered definition, hidden ones included, with vocabulary" do
      catalog = described_class.catalog

      expect(catalog[:definitions].map { |row| row[:key] }).to eq(Achievements::Registry.default.keys)
      expect(catalog[:definitions].map { |row| row[:visibility] }).to include(:hidden)
      expect(catalog[:vocabulary][:scope]).to eq(%i[instance user])
      expect(catalog[:vocabulary][:trigger]).to include("job.closed", "epic.upserted")
      expect(catalog[:problems]).to eq([])
    end

    it "classifies implementation status from the runtime's evaluators and event adapters" do
      implemented = Achievements::Definition.build(key: "x.a", scope: :user, trigger: "job.closed", evaluator: "Achievements::Evaluators::FirstOccurrence", subject_kinds: %i[job], category: :work, rarity: :common)
      partial = Achievements::Definition.build(key: "x.b", scope: :user, trigger: "job.closed", evaluator: "Missing::Evaluator", subject_kinds: %i[job], category: :work, rarity: :common)
      planned = Achievements::Definition.build(key: "x.c", scope: :user, trigger: "later.event", evaluator: "Missing::Evaluator", subject_kinds: %i[job], category: :work, rarity: :common)

      expect([ implemented, partial, planned ].map { |definition| described_class.implementation_status(definition) }).to eq(%w[implemented partial planned])
    end
  end
end
