require "rails_helper"

# End-to-end smoke test: registers the syrus_rails plugin, writes a typed artifact
# via the MCP tool, serializes via JobDetailPayload, and verifies renderer_type is
# present in the API response.
RSpec.describe "typed artifacts in job detail payload" do
  around do |example|
    Syrus::PluginRegistry.reset!
    example.run
    Syrus::PluginRegistry.reset!
  end

  def payload_for(job, user)
    App::JobDetailPayload.build(job: job, user: user)
  end

  it "injects renderer_type for rails_schema_erd artifacts using the registered plugin" do
    Syrus::PluginRegistry.register(
      name:    "syrus-rails",
      version: "0.1.0",
      provides: {
        artifact_renderer: [
          SyrusRails::SchemaErdRenderer,
          SyrusRails::MigrationDiffRenderer
        ]
      }
    )

    run = Factories.job.initial_run
    job = run.job

    SyrusMcp::SubmitArtifactTool.call(
      type:    "rails_schema_erd",
      title:   "Schema ERD",
      payload: { "tables" => [ { "name" => "users", "columns" => [] } ] },
      server_context: { run: run }
    )

    workflows = payload_for(job, job.user)[:workflows]
    typed = workflows.flat_map { |w| (w[:artifacts] || {}).fetch("typed_artifacts", []) }

    erd_entry = typed.find { |e| e["type"] == "rails_schema_erd" }
    expect(erd_entry).to be_present
    expect(erd_entry["renderer_type"]).to eq("erd_diagram")
  end

  it "injects renderer_type for rails_migration_diff artifacts" do
    Syrus::PluginRegistry.register(
      name:    "syrus-rails",
      version: "0.1.0",
      provides: { artifact_renderer: [ SyrusRails::MigrationDiffRenderer ] }
    )

    run = Factories.job.initial_run
    job = run.job

    SyrusMcp::SubmitArtifactTool.call(
      type:    "rails_migration_diff",
      title:   "Add email to users",
      payload: { "migration_name" => "AddEmailToUsers", "changes" => [] },
      server_context: { run: run }
    )

    workflows = payload_for(job, job.user)[:workflows]
    typed = workflows.flat_map { |w| (w[:artifacts] || {}).fetch("typed_artifacts", []) }

    diff_entry = typed.find { |e| e["type"] == "rails_migration_diff" }
    expect(diff_entry).to be_present
    expect(diff_entry["renderer_type"]).to eq("migration_diff")
  end

  it "passes through artifacts with no registered renderer without renderer_type" do
    run = Factories.job.initial_run
    job = run.job

    SyrusMcp::SubmitArtifactTool.call(
      type:    "custom_artifact",
      title:   "Custom",
      payload: { "data" => 1 },
      server_context: { run: run }
    )

    workflows = payload_for(job, job.user)[:workflows]
    typed = workflows.flat_map { |w| (w[:artifacts] || {}).fetch("typed_artifacts", []) }

    custom_entry = typed.find { |e| e["type"] == "custom_artifact" }
    expect(custom_entry).to be_present
    expect(custom_entry).not_to have_key("renderer_type")
  end

  it "does not modify workflows without typed_artifacts" do
    run = Factories.job.initial_run
    job = run.job
    Workflow.create!(
      job: job,
      user: job.user,
      trigger_kind: "initial",
      state: "succeeded",
      artifacts: { "test_plan" => { "steps" => [ "Run tests" ] } }
    )

    workflows = payload_for(job, job.user)[:workflows]
    non_typed = workflows.find { |w| w[:artifacts].is_a?(Hash) && !w[:artifacts].key?("typed_artifacts") }
    expect(non_typed).to be_present
    expect(non_typed[:artifacts]).to eq({ "test_plan" => { "steps" => [ "Run tests" ] } })
  end
end
