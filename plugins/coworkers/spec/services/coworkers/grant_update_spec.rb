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
      constraints: { confirm_paths: [ "SOUL.md", "AGENTS.md", "SOUL.md" ] }, confirmed: true)
    expect(coworker.grants.last.constraints).to eq("confirm_paths" => %w[SOUL.md AGENTS.md])
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

  it "enforces a declaring owner's maximum policy" do
    descriptor = Coworkers::GrantCatalog::Descriptor.new(
      name: "limited.read", label: "Limited", description: "Limited", maximum_policy: "confirm", tools: [],
      scope_options_callback: nil, scope_label_callback: nil, valid_scope_callback: nil
    )
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("limited.read").and_return(descriptor)

    expect {
      described_class.call(owner: owner, coworker: coworker, capability: "limited.read", approval_policy: "auto", confirmed: true)
    }.to raise_error(ArgumentError, /exceeds maximum confirm/)
  end

  it "persists a valid scope and confirms subsequent scope changes" do
    descriptor = Coworkers::GrantCatalog::Descriptor.new(
      name: "scoped.read", label: "Scoped", description: "Scoped", maximum_policy: "auto", tools: [],
      scope_options_callback: ->(user:) { [ user.id, user.id + 1 ] }, scope_label_callback: ->(value) { value.to_s },
      valid_scope_callback: ->(value, user:) { [ user.id, user.id + 1 ].include?(value) }
    )
    allow(Coworkers::GrantCatalog).to receive(:fetch).with("scoped.read").and_return(descriptor)
    described_class.call(owner: owner, coworker: coworker, capability: "scoped.read", approval_policy: "confirm", scope: owner.id, confirmed: true)
    grant = coworker.grants.find_by!(capability: "scoped.read")
    expect(grant.scope).to eq(owner.id)

    expect {
      described_class.call(owner: owner, coworker: coworker, capability: "scoped.read", approval_policy: "confirm", scope: owner.id + 1)
    }.to raise_error(Coworkers::GrantUpdate::ConfirmationRequired)
  end
end
