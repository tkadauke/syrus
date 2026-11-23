require "rails_helper"
RSpec.describe Coworkers::RunContextContributor do
  it "hard-fails when the pinned reviewer plugin disappears" do
    job = instance_double(Job, owner_user: double, user: double, repository: double)
    run = instance_double(Run, job: job, step: instance_double(Step, details: { "reviewer_target" => { "type" => "coworker", "reference" => "gone" } }))
    allow(Syrus::Plugin::ReviewContributions).to receive(:contributions).and_call_original
    allow(Syrus::Plugin::ReviewContributions).to receive(:contributions).with(:reviewer_target_providers).and_return([])
    expect { described_class.context_attributes(run: run, role: AgentRole::WORKFLOW_COWORKER_REVIEWER) }.to raise_error(ReviewerTargets::PluginUnavailable)
  end

  it "projects permissions once while building a coworker run context" do
    coworker = instance_double(Coworkers::Coworker, readable_chat_session_ids: [ 1 ], coworker_chats: double)
    rules = instance_double(Coworkers::PermissionRules, entries: [
      { capability: "code.read", approval_policy: "auto", scope: [ 7 ], constraints: {} }
    ])
    allow(coworker).to receive(:permission_rules).and_return(rules)
    allow(coworker.coworker_chats).to receive(:find_by).with(role: "main").and_return(nil)
    allow(Coworkers::Coworker).to receive(:find_by).with(id: "42").and_return(coworker)
    allow(Coworkers::PrivilegedGrantGate).to receive(:allowed_capabilities_from_entries)
      .and_return([ "code.read" ])
    job = instance_double(Job, origin: "coworkers", origin_id: "42")
    run = instance_double(Run, job: job, step: instance_double(Step, details: {}))

    attributes = described_class.context_attributes(run: run, role: AgentRole::COWORKER)

    expect(attributes).to include(granted_capabilities: [ "code.read" ], capability_scopes: { "code.read" => [ 7 ] })
    expect(rules).to have_received(:entries).once
    expect(Coworkers::PrivilegedGrantGate).to have_received(:allowed_capabilities_from_entries).once
  end

  it "builds the bundled coworker capability catalog within a bounded query budget" do
    owner = Factories.user(email_address: "context-budget@example.com")
    coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Budget", handle: "catalog-budget",
      workspace_repo: "https://github.com/example/context-budget.git"
    )
    job = instance_double(Job, origin: "coworkers", origin_id: coworker.id.to_s)
    run = instance_double(Run, job: job, step: instance_double(Step, details: {}))
    queries = []
    subscriber = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached]
    end

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    attributes = ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      described_class.context_attributes(run: run, role: AgentRole::COWORKER)
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(attributes).to include(:granted_capabilities, :capability_scopes, :agent_actor)
    expect(queries.size).to be <= 30
    expect(elapsed).to be < 1.0
    expect(queries.grep(/FROM [`\"]?kubernetes_clusters[`\"]?/i).size).to be <= 1
    expect(queries.grep(/FROM [`\"]?mysql_connections[`\"]?/i).size).to be <= 1
  end
end
