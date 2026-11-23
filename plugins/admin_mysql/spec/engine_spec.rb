require "rails_helper"

RSpec.describe AdminMysql::Engine do
  it "registers the scoped permission provider once enabled" do
    expect(permission_providers).not_to include(AdminMysql::PermissionProvider)

    PluginRecord.find_by!(name: "admin_mysql").update!(enabled: true)

    expect(permission_providers).to include(AdminMysql::PermissionProvider)
  end
end
