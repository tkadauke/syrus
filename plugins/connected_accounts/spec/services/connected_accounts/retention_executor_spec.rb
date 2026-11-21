require "rails_helper"

RSpec.describe ConnectedAccounts::RetentionExecutor do
  it "purges expired disconnected accounts and their old broker audit history" do
    definition = instance_double(RetentionPolicyRegistry::Definition, retention_window: 30.days)
    relation = instance_double(ActiveRecord::Relation)
    allow(ConnectedAccounts::Account).to receive(:retention_candidates).and_return(relation)
    allow(relation).to receive(:where).and_return(relation)
    allow(relation).to receive(:limit).and_return(relation)
    allow(relation).to receive(:pluck).and_return([ 42 ])
    allow(relation).to receive(:select).and_return(relation)
    allow(relation).to receive(:exists?).and_return(false)
    allow(ConnectedAccounts::Account).to receive(:where).with(id: relation).and_return(instance_double(ActiveRecord::Relation, delete_all: 1))
    audits = instance_double(ActiveRecord::Relation, delete_all: 2)
    allow(CredentialStore::CredentialAccessEvent).to receive(:where).and_return(audits)

    result = described_class.new(definition).call

    expect(result).to have_attributes(deleted_count: 3, backlog: false)
  end
end
