require "rails_helper"
require Rails.root.join("db/migrate/20260513120000_retire_ci_failure_workflows").to_s

RSpec.describe RetireCiFailureWorkflows do
  let(:connection) { ActiveRecord::Base.connection }
  let(:job) { Factories.job }

  def insert_row(table, attrs)
    columns = attrs.keys.map { |key| connection.quote_column_name(key) }.join(", ")
    values = attrs.values.map { |value| connection.quote(value) }.join(", ")
    connection.insert("INSERT INTO #{connection.quote_table_name(table)} (#{columns}) VALUES (#{values})")
  end

  it "cancels active ci_failure workflows and records the retirement reason" do
    now = Time.current
    workflow_id = insert_row("workflows", {
      job_id: job.id,
      trigger_kind: "ci_failure",
      state: "running",
      agent_provider: "claude",
      artifacts: { "head_sha" => "abc123" }.to_json,
      created_at: now,
      updated_at: now
    })
    step_id = insert_row("steps", {
      workflow_id: workflow_id,
      kind: "analyze_and_fix",
      state: "running",
      position: 0,
      created_at: now,
      updated_at: now
    })
    run_id = insert_row("runs", {
      job_id: job.id,
      step_id: step_id,
      trigger_kind: "ci_failure",
      state: "running",
      agent_provider: "claude",
      created_at: now,
      updated_at: now
    })

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    workflow = connection.select_one("SELECT state, finished_at, artifacts FROM workflows WHERE id = #{workflow_id}")
    step = connection.select_one("SELECT state, finished_at FROM steps WHERE id = #{step_id}")
    run = connection.select_one("SELECT state, finished_at FROM runs WHERE id = #{run_id}")

    expect(workflow["state"]).to eq("cancelled")
    expect(step["state"]).to eq("cancelled")
    expect(run["state"]).to eq("cancelled")
    expect(workflow["finished_at"]).to be_present
    expect(step["finished_at"]).to be_present
    expect(run["finished_at"]).to be_present
    expect(JSON.parse(workflow["artifacts"])).to include(
      "head_sha" => "abc123",
      "cancellation_reason" => "superseded_by_grade"
    )
  end

  it "leaves terminal historical ci_failure workflows untouched" do
    now = Time.current
    workflow_id = insert_row("workflows", {
      job_id: job.id,
      trigger_kind: "ci_failure",
      state: "failed",
      agent_provider: "claude",
      artifacts: { "head_sha" => "old" }.to_json,
      created_at: now,
      updated_at: now
    })

    ActiveRecord::Migration.suppress_messages { described_class.new.up }

    workflow = connection.select_one("SELECT state, artifacts FROM workflows WHERE id = #{workflow_id}")
    expect(workflow["state"]).to eq("failed")
    expect(JSON.parse(workflow["artifacts"])).to eq("head_sha" => "old")
  end
end
