require "rails_helper"
require Rails.root.join("db/migrate/20261123055429_enable_telegram_plugin_for_configured_instances")

RSpec.describe EnableTelegramPluginForConfiguredInstances do
  let(:migration) { described_class.new }

  def run_up
    ActiveRecord::Migration.suppress_messages { migration.migrate(:up) }
  end

  before { PluginRecord.find_by!(name: "telegram").update!(enabled: false) }

  it "enables the plugin on an instance with a configured bot token" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")

    run_up

    expect(PluginRecord.find_by!(name: "telegram")).to be_enabled
  end

  it "is idempotent" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")

    2.times { run_up }

    expect(PluginRecord.where(name: "telegram").count).to eq(1)
    expect(PluginRecord.find_by!(name: "telegram")).to be_enabled
  end

  it "creates the record enabled when the plugin has not registered yet" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")
    PluginRecord.where(name: "telegram").delete_all

    run_up

    expect(PluginRecord.find_by!(name: "telegram")).to be_enabled
  end

  it "leaves the plugin disabled when no token is configured" do
    AppSetting.current.update_column(:telegram_bot_token, nil)

    run_up

    expect(PluginRecord.find_by!(name: "telegram")).not_to be_enabled
  end
end
