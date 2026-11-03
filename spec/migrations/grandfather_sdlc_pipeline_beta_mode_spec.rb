require "rails_helper"
require Rails.root.join("db/migrate/20261103071638_grandfather_sdlc_pipeline_beta_mode")

RSpec.describe GrandfatherSdlcPipelineBetaMode do
  let(:migration) { described_class.new }

  def beta_mode?
    AppSetting.connection.select_value("SELECT beta_mode_enabled FROM app_settings LIMIT 1").in?([ true, 1 ])
  end

  before do
    AppSetting.current
    AppSetting.update_all(beta_mode_enabled: false)
  end

  it "turns beta mode on when the plugin was already enabled" do
    PluginRecord.find_or_create_by!(name: "sdlc_pipeline").update!(enabled: true)

    migration.suppress_messages { migration.up }

    expect(beta_mode?).to be(true)
  end

  it "leaves beta mode off when the plugin was not enabled" do
    PluginRecord.find_or_create_by!(name: "sdlc_pipeline").update!(enabled: false)

    migration.suppress_messages { migration.up }

    expect(beta_mode?).to be(false)
  end
end
