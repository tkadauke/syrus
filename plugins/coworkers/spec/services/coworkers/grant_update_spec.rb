require "rails_helper"

RSpec.describe Coworkers::GrantUpdate do
  let(:owner) { Factories.user }
  let(:coworker) { Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-policy", workspace_repo: "git@example.com:workspace.git") }

  %w[off queue confirm auto].product(%w[off queue confirm auto]).reject { |from, to| from == to }.each do |from, to|
    it "changes #{from} to #{to} with confirmation only for escalation" do
      coworker.grants.create!(capability: "workspace.files", approval_policy: from) unless from == "off"
      escalation = Coworkers::GrantPolicy.for(to).escalation_from?(from)
      if escalation
        expect { described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: to) }
          .to raise_error(Coworkers::GrantUpdate::ConfirmationRequired)
      end
      described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: to, confirmed: escalation)
      expect(coworker.grants.find_by(capability: "workspace.files")&.approval_policy || "off").to eq(to)
    end
  end

  it "stores supported file constraints" do
    described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "confirm",
      constraints: { confirm_paths: [ "./SOUL.md", "memory/../AGENTS.md", "SOUL.md" ] }, confirmed: true)
    expect(coworker.grants.last.constraints).to eq("confirm_paths" => %w[SOUL.md AGENTS.md])
  end

  it "rejects protected paths outside the workspace jail" do
    expect {
      described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "confirm",
        constraints: { confirm_paths: [ "../SOUL.md" ] }, confirmed: true)
    }.to raise_error(ArgumentError, /inside the coworker workspace/)
  end

  it "requires confirmation before removing a protected file path" do
    grant = coworker.grants.create!(
      capability: "workspace.files", approval_policy: "confirm",
      constraints: { "confirm_paths" => %w[SOUL.md AGENTS.md] }
    )

    expect {
      described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "confirm",
        constraints: { confirm_paths: [ "SOUL.md" ] })
    }.to raise_error(Coworkers::GrantUpdate::ConfirmationRequired)
    expect(grant.reload.constraints).to eq("confirm_paths" => %w[SOUL.md AGENTS.md])

    described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "confirm",
      constraints: { confirm_paths: [ "SOUL.md" ] }, confirmed: true)
    expect(grant.reload.constraints).to eq("confirm_paths" => [ "SOUL.md" ])
  end

  it "adds a protected file path without escalation confirmation" do
    grant = coworker.grants.create!(
      capability: "workspace.files", approval_policy: "confirm",
      constraints: { "confirm_paths" => [ "SOUL.md" ] }
    )

    described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "confirm",
      constraints: { confirm_paths: %w[SOUL.md AGENTS.md] })
    expect(grant.reload.constraints).to eq("confirm_paths" => %w[SOUL.md AGENTS.md])
  end

  it "revokes a constrained file grant without escalation confirmation" do
    coworker.grants.create!(
      capability: "workspace.files", approval_policy: "confirm",
      constraints: { "confirm_paths" => %w[SOUL.md AGENTS.md] }
    )

    described_class.call(owner: owner, coworker: coworker, capability: "workspace.files", approval_policy: "off")
    expect(coworker.grants.find_by(capability: "workspace.files")).to be_nil
  end

  it "does not let a coworker change its own grants" do
    expect { described_class.call(owner: coworker, coworker: coworker, capability: "workspace.files", approval_policy: "auto", confirmed: true) }
      .to raise_error(Pundit::NotAuthorizedError)
    expect(coworker.grants).to be_empty
  end

  it "preserves an existing scope when only the policy changes and permits revocation" do
    descriptor = Coworkers::GrantCatalog::Descriptor.new(
      name: "scoped.read", label: "Scoped", description: "Scoped", maximum_policy: "auto", tools: [],
      scope_options_callback: ->(user:) { [ user.id ] }, scope_label_callback: ->(value) { value.to_s },
      valid_scope_callback: ->(value, user:) { value == user.id }
    )
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("scoped.read").and_return(descriptor)
    grant = coworker.grants.create!(capability: "scoped.read", approval_policy: "confirm", scope: owner.id)

    described_class.call(owner: owner, coworker: coworker, capability: "scoped.read", approval_policy: "queue")
    expect(grant.reload).to have_attributes(approval_policy: "queue", scope: owner.id)

    described_class.call(owner: owner, coworker: coworker, capability: "scoped.read", approval_policy: "off")
    expect(coworker.grants.find_by(capability: "scoped.read")).to be_nil
  end
end
