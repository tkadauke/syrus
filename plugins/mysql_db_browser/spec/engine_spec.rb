require "rails_helper"

RSpec.describe MysqlDbBrowser::Engine do
  it "is registered disabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "mysql_db_browser" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.enabled?).to be(false)
  end

  describe ".enabled?" do
    it "is false when neither the Feature flag nor the plugin record are enabled" do
      expect(MysqlDbBrowser.enabled?).to be(false)
    end

    it "is false when only the Feature flag is enabled" do
      Feature.create!(slug: "mysql_db_browser", category: "Labs", name: "MySQL DB browser", enabled: true)

      expect(MysqlDbBrowser.enabled?).to be(false)
    end

    it "is false when only the plugin record is enabled" do
      PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

      expect(MysqlDbBrowser.enabled?).to be(false)
    end

    it "is true once both the Feature flag and the plugin record are enabled" do
      Feature.create!(slug: "mysql_db_browser", category: "Labs", name: "MySQL DB browser", enabled: true)
      PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

      expect(MysqlDbBrowser.enabled?).to be(true)
    end
  end
end
