require "rails_helper"
require Rails.root.join("plugins/telegram/db/migrate/20261123120000_enable_telegram_plugin_for_configured_instances.rb")

RSpec.describe EnableTelegramPluginForConfiguredInstances do
  let(:record) { PluginRecord.find_by!(name: "telegram") }

  def migrate_up
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  it "enables the plugin on an instance with a configured bot token" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")
    record.update!(enabled: false)

    migrate_up

    expect(record.reload).to be_enabled
  end

  it "is idempotent" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")

    2.times { migrate_up }

    expect(record.reload).to be_enabled
  end

  it "creates the disabled-by-default record when the plugin has not registered yet" do
    AppSetting.current.update!(telegram_bot_token: "123:abc")
    record.destroy!

    migrate_up

    fresh = PluginRecord.find_by!(name: "telegram")
    expect(fresh).to be_enabled
    expect(fresh.default_enabled).to be(false)
  end

  it "leaves the plugin disabled when no bot token is configured" do
    AppSetting.current.update!(telegram_bot_token: nil)
    record.update!(enabled: false)

    migrate_up

    expect(record.reload).not_to be_enabled
  end
end
