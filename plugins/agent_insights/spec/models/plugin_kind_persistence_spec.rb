require "rails_helper"

# A Job, Workflow, Step or Run keeps the kind it was created with. Disabling
# the plugin that contributed that kind removes it from the kind registry
# (KindRegistry installs and tears kinds down), but an existing row must still
# be cancellable and finishable afterwards: validating its unchanged kind
# against the current registry made every save raise RecordInvalid, so work
# already running on a now-disabled plugin's kind could never be cancelled.
# New rows, and rows whose kind changes, are still checked
# (formal/SyrusModel/PluginDisableRecovery.lean).
RSpec.describe "plugin-contributed kinds after their plugin is disabled" do
  def set_enabled(enabled)
    PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: enabled, disableable: true)
  end

  let(:job) do
    set_enabled(true)
    Factories.job_with_run(
      kind: "agent_insight", issue_number: nil,
      state: "running",
      workflow_attrs: { trigger_kind: "agent_insight", state: "running" },
      step_attrs: { kind: "agent_insight_run", state: "running" },
      run_attrs: { state: "running" }
    )
  end
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first }

  before do
    job
    set_enabled(false)
    expect(Step::Kind.values).not_to include("agent_insight_run")
  end

  it "still saves an existing step, workflow, run and job of the removed kinds" do
    expect { step.update!(state: "cancelled") }.not_to raise_error
    [ run, workflow, job.reload ].each do |record|
      expect(record).to be_valid, -> { "#{record.class}: #{record.errors.full_messages}" }
    end
    expect { workflow.update!(updated_at: Time.current) }.not_to raise_error
  end

  # The kinds go away with the plugin (disabled, or unhealthy after boot), and
  # with them the WorkDefinition the cancel cascade consulted: cancelling
  # in-flight work of those kinds raised WorkDefinitions::UnknownKind, so it
  # could be neither finished nor cancelled (NY14).
  it "can still cancel the in-flight workflow, its steps and runs" do
    expect { WorkUnits::WorkflowCancellation.cancel!(workflow, reason: "plugin_unavailable") }.not_to raise_error

    expect(workflow.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(run.reload).to be_cancelled
  end

  it "still rejects new rows of a kind no installed plugin provides" do
    expect(Step.new(workflow: workflow, kind: "agent_insight_run", position: 1, state: "queued")).not_to be_valid
    expect(Workflow.new(job: job, user: job.user, trigger_kind: "agent_insight", agent_provider: job.agent_provider, priority: job.priority)).not_to be_valid
  end

  it "still rejects changing an existing row to a kind no installed plugin provides" do
    implement = Step.create!(workflow: workflow, kind: "implement", position: 1, state: "queued")
    implement.kind = "agent_insight_run"

    expect(implement).not_to be_valid
    expect(implement.errors[:kind]).to be_present
  end
end
