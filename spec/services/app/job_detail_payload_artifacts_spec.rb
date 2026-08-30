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
  describe "resource admission diagnostics visibility" do
    # The `user` let is the first User created in the example, so
    # User#promote_first_user_to_admin makes it an admin. A second user
    # created afterward is a genuine non-admin.
    it "hides the admin diagnostics link for non-admin users" do
      job = Factories.job_record(user: user, repository: repo)
      non_admin = Factories.user

      result = described_class.build(job: job, user: non_admin)
      expect(result.dig(:actions, :can_view_resource_admission_diagnostics)).to be(false)
    end

    it "exposes the admin diagnostics link for admin users" do
      job = Factories.job_record(user: user, repository: repo)

      result = described_class.build(job: job, user: user)
      expect(result.dig(:actions, :can_view_resource_admission_diagnostics)).to be(true)
      expect(result.dig(:paths, :admin_resource_admission_path)).to eq("/admin/resource_admission")
    end
  end

  describe "#typed_artifacts" do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "returns an empty array when no workflow has typed_artifacts" do
      job = Factories.job_record(user: user, repository: repo)

      expect(payload_for(job).fetch(:typed_artifacts)).to eq([])
    end

    it "includes typed artifacts from a workflow's artifacts" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Schema ERD", "payload" => { "tables" => [] }, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first).to include(
        type: "rails_schema_erd",
        title: "Schema ERD",
        payload: { "tables" => [] },
        created_at: "2026-08-06T10:00:00Z",
        renderer_type: nil
      )
    end

    it "annotates artifacts with renderer_type from a registered artifact_renderer plugin" do
      renderer_class = Class.new do
        include Syrus::Plugin::ArtifactRenderer
        def self.artifact_type = "rails_schema_erd"
        def self.renderer_type = :erd_diagram
      end

      Syrus::PluginRegistry.register(
        name: "test_renderer_plugin", version: "1.0.0",
        provides: { artifact_renderer: renderer_class }
      )

      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Schema ERD", "payload" => {}, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.first).to include(renderer_type: "erd_diagram")
    end

    it "deduplicates by type across workflows, keeping the most recent entry" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Old ERD", "payload" => { "version" => 1 }, "created_at" => "2026-08-06T09:00:00Z" }
          ]
        }
      )
      Workflow.create!(
        job: job, trigger_kind: "retry", state: "succeeded",
        created_at: Time.current,
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "Updated ERD", "payload" => { "version" => 2 }, "created_at" => "2026-08-06T10:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first[:title]).to eq("Updated ERD")
    end

    it "includes artifacts of different types from multiple workflows" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: {
          "typed_artifacts" => [
            { "type" => "rails_schema_erd", "title" => "ERD", "payload" => {}, "created_at" => "2026-08-06T09:00:00Z" },
            { "type" => "rails_migration_diff", "title" => "Diff", "payload" => {}, "created_at" => "2026-08-06T09:00:00Z" }
          ]
        }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.map { |a| a[:type] }).to contain_exactly("rails_schema_erd", "rails_migration_diff")
    end

    it "skips artifact entries that are not hashes" do
      job = Factories.job_record(user: user, repository: repo)
      Workflow.create!(
        job: job, trigger_kind: "initial", state: "succeeded",
        artifacts: { "typed_artifacts" => [ nil, "bad", { "type" => "ok", "title" => "OK", "payload" => {}, "created_at" => "2026-08-06T10:00:00Z" } ] }
      )

      artifacts = payload_for(job).fetch(:typed_artifacts)
      expect(artifacts.size).to eq(1)
      expect(artifacts.first[:type]).to eq("ok")
    end
  end

end
