require "rails_helper"

RSpec.describe ConnectedAccounts::PurgeContributor do
  it "reports and removes credential audit rows held outside the plugin tables" do
    relation = instance_double(ActiveRecord::Relation)
    allow(CredentialStore::CredentialAccessEvent).to receive(:where).and_return(relation)
    allow(relation).to receive(:count).and_return(2)
    allow(relation).to receive(:delete_all).and_return(2)

    expect(described_class.purge_report("connected_accounts")).to eq([ "2 connected-account credential audit rows" ])
    expect(described_class.purge!("connected_accounts")).to eq([ "2 connected-account credential audit rows" ])
    expect(described_class.purge!("another_plugin")).to eq([])
  end
end
