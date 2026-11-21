require "rails_helper"

RSpec.describe CredentialStore::PurgeContributor do
  it "removes namespaced credentials after the owning plugin's tables are dropped" do
    connection = ActiveRecord::Base.connection
    connection.create_table(:example_plugin_records)
    user = Factories.user
    credential = create_credential(user:, name: "managed", credential_type: "example_plugin.oauth")
    retained = create_credential(user:, name: "retained", credential_type: "exampleXplugin.oauth")
    audit = CredentialStore::CredentialAccessEvent.record!(credential:, user:, surface: "api",
      action: "create", result: "allowed", tool_name: "example_plugin.broker")
    purge = Syrus::PluginPurge.new("example_plugin")
    allow(purge).to receive(:tables).and_return([ "example_plugin_records" ])
    allow(purge).to receive(:contributors).and_return([ described_class ])

    expect(purge.report.other_data).to contain_exactly(
      "1 plugin credential audit rows", "1 plugin-managed encrypted credentials")
    expect(purge.purge!).to include("example_plugin_records", "1 plugin credential audit rows",
      "1 plugin-managed encrypted credentials")
    expect(connection.table_exists?(:example_plugin_records)).to be(false)
    expect(CredentialStore::CredentialAccessEvent.where(id: audit.id)).not_to exist
    expect(CredentialStore::Credential.where(id: credential.id)).not_to exist
    expect(CredentialStore::Credential.where(id: retained.id)).to exist
  ensure
    connection&.drop_table(:example_plugin_records, if_exists: true)
  end

  it "does not query its own tables after Credential Store is purged" do
    expect(described_class.purge_report("credential_store")).to eq([])
    expect(described_class.purge!("credential_store")).to eq([])
  end

  def create_credential(user:, name:, credential_type:)
    CredentialStore::Credential.create!(name:, credential_type:, scope_type: "user", scope_id: user.id,
      created_by: user, owner_user: user, payload: { access_token: "secret" }.to_json, safe_metadata: {},
      target_constraints: { "allowed_url_prefixes" => [ "https://api.example/" ] },
      allowed_tools: [ "example_plugin.broker" ])
  end
end
