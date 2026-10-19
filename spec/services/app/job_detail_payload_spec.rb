require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end

  it "exposes active provider routing hold wake details" do
    job = Factories.job(user: user, repository: repo)
    workflow = job.workflows.first
    rule = ProviderRoutingRule.create!(
      scope_type: "job", scope_id: job.id, task_key: "initial", candidates: [],
      action: { type: "hold", reason: "Await approval", resumption: { mode: "until_time", at: 1.hour.from_now.iso8601 } }
    )
    wake_at = 1.hour.from_now.change(usec: 0)
    hold = ProviderRoutingHold.create!(
      workflow: workflow, provider_routing_rule: rule, resumption_mode: "until_time",
      next_reevaluation_at: wake_at, reason: "Await approval",
      condition_evidence: { "matched" => true },
      matched_scope: { "source_scope" => "job", "source_id" => job.id }
    )

    expect(payload_for(job).dig(:job, :active_provider_routing_holds)).to contain_exactly(
      include(id: hold.id, workflow_id: workflow.id, reason: "Await approval", resumption_mode: "until_time", next_reevaluation_at: wake_at.iso8601)
    )
  end
end
