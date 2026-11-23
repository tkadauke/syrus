require "rails_helper"
require Rails.root.join("db/migrate/20261123070533_enable_connected_accounts_for_bot_token_plugins")

RSpec.describe EnableConnectedAccountsForBotTokenPlugins do
  def run_up
    ActiveRecord::Migration.suppress_messages { described_class.new.migrate(:up) }
  end

  def enabled?(name) = PluginRecord.find_by!(name: name).enabled?

  before do
    %w[telegram discord credential_store connected_accounts].each { |name| PluginRecord.find_by!(name: name).update!(enabled: false) }
  end

  %w[telegram discord].each do |platform|
    it "enables the dependencies on an instance running #{platform}" do
      PluginRecord.find_by!(name: platform).update!(enabled: true)

      run_up

      expect(enabled?("credential_store")).to be(true)
      expect(enabled?("connected_accounts")).to be(true)
    end
  end

  it "leaves an instance running neither platform alone" do
    run_up

    expect(enabled?("credential_store")).to be(false)
    expect(enabled?("connected_accounts")).to be(false)
  end

  it "is idempotent" do
    PluginRecord.find_by!(name: "telegram").update!(enabled: true)

    2.times { run_up }

    expect(PluginRecord.where(name: "connected_accounts").count).to eq(1)
    expect(enabled?("connected_accounts")).to be(true)
  end
end
