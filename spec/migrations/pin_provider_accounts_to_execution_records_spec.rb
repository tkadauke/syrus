require "rails_helper"
require Rails.root.join("db/migrate/20261119192638_pin_provider_accounts_to_execution_records")

RSpec.describe PinProviderAccountsToExecutionRecords do
  let(:migration) { described_class.new }
  let(:user) { Factories.user }

  def provider_account(position:, label:)
    ProviderAccount.create!(
      user: user, provider_key: "claude", position: position, label: label,
      authentication_kind: "oauth", credential_payload: { "token" => "test" }
    )
  end

  def unpinned_run
    run = Factories.run(user: user)
    run.workflow.update_columns(agent_provider: "claude", provider_account_id: nil)
    run.update_columns(agent_provider: "claude", provider_account_id: nil)
    run
  end

  it "backfills every row across id-range batches without one table-wide statement" do
    stub_const("#{described_class}::BATCH_SIZE", 1)
    default_account = provider_account(position: 0, label: "default")
    runs = Array.new(3) { unpinned_run }
    executed = []
    allow(migration).to receive(:execute).and_wrap_original do |original, sql|
      executed << sql
      original.call(sql)
    end

    migration.up

    expect(runs.map { |run| run.reload.provider_account_id }).to all(eq(default_account.id))
    expect(runs.map { |run| run.workflow.reload.provider_account_id }).to all(eq(default_account.id))
    run_updates = executed.grep(/\AUPDATE runs /)
    expect(run_updates.size).to be >= runs.size
    expect(run_updates).to all(include("runs.id BETWEEN"))
  end

  it "runs outside a migration transaction so each batch commits on its own" do
    expect(described_class.new.disable_ddl_transaction).to be(true)
  end

  it "leaves already-pinned rows alone and is idempotent" do
    provider_account(position: 0, label: "default")
    other_account = provider_account(position: 1, label: "other")
    pinned = unpinned_run
    pinned.update_columns(provider_account_id: other_account.id)

    2.times { migration.up }

    expect(pinned.reload.provider_account_id).to eq(other_account.id)
  end
end
