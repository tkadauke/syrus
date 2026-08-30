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
end
