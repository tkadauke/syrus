require "rails_helper"

RSpec.describe AdminMysql::Engine do
  it "registers the scoped permission provider once enabled" do
    expect(Syrus::PluginRegistry.providers_for(:permission_provider)).not_to include(AdminMysql::PermissionProvider)

    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:permission_provider)).to include(AdminMysql::PermissionProvider)
  end
end
