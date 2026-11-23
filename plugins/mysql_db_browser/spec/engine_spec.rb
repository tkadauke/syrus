require "rails_helper"

RSpec.describe MysqlDbBrowser::Engine do
  it "is registered disabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "mysql_db_browser" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.enabled?).to be(false)
    expect(manifest.depends_on).to eq([ "credential_store" ])
    expect(manifest.credential_types.map { |entry| entry.fetch("name") }).to include("mysql_db_browser.connection")
    expect(manifest.metadata[:frontend]).to eq(
      routes: { "mysql_db_browser/MysqlConnections" => "app/frontend/routes/MysqlConnections.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/mysql_db_browser.json" ]
    )
  end

  it "registers the DB Browser sidebar page provider even before the plugin is enabled" do
    expect(surface_implementations(:sidebar_pages)).not_to include(MysqlDbBrowser::SidebarPages)

    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

    expect(surface_implementations(:sidebar_pages)).to include(MysqlDbBrowser::SidebarPages)
  end

  it "registers the agentic-access workflow and chat MCP tool set providers once the plugin is enabled" do
    expect(workflow_tool_sets).not_to include(MysqlDbBrowser::WorkflowToolSet)
    expect(chat_tool_sets).not_to include(MysqlDbBrowser::ChatToolSet)

    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

    expect(workflow_tool_sets).to include(MysqlDbBrowser::WorkflowToolSet)
    expect(chat_tool_sets).to include(MysqlDbBrowser::ChatToolSet)
    expect(permission_providers).to include(MysqlDbBrowser::PermissionProvider)
  end

  describe ".enabled?" do
    it "is false when the plugin record is not enabled" do
      expect(MysqlDbBrowser.enabled?).to be(false)
    end

    it "is true once the plugin record is enabled" do
      PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

      expect(MysqlDbBrowser.enabled?).to be(true)
    end

    it "is false when credential_store is disabled" do
      PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
      PluginRecord.find_by!(name: "credential_store").update!(enabled: false)

      expect(MysqlDbBrowser.enabled?).to be(false)
    end
  end
end
