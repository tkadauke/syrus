require "rails_helper"
require "tmpdir"

RSpec.describe WorkflowWorkspacePruneJob do
  let(:data_root) { Dir.mktmpdir("syrus-prune-data") }

  before do
    ENV["SYRUS_DATA_ROOT"] = data_root
    # Stub filesystem cleanup so DB-sweep examples exercise query logic
    # without touching disk. WorkflowWorkspace.cleanup_for is tested
    # separately in the WorkflowWorkspace spec.
    allow(WorkflowWorkspace).to receive(:cleanup_for) do |wf|
      wf.update_columns(cleaned_up_at: Time.current)
    end
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(data_root)
  end

  def make_workflow(state:, finished_at: nil, cleaned_up_at: nil)
    job = Factories.job
    wf  = Workflow.create!(job: job, trigger_kind: "initial")
    wf.update_columns(state: state, finished_at: finished_at, cleaned_up_at: cleaned_up_at)
    wf
  end

  # ---- db_sweep: succeeded / cancelled use short retention --------

  it "db_sweep cleans succeeded workflows past RETAIN_AFTER_SUCCESS_OR_CANCEL" do
    old = make_workflow(
      state: "succeeded",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.minute).ago
    )
    expect(WorkflowWorkspace).to receive(:cleanup_for).with(old)
    described_class.perform_now
  end

  it "db_sweep cleans cancelled workflows past RETAIN_AFTER_SUCCESS_OR_CANCEL" do
    old = make_workflow(
      state: "cancelled",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.minute).ago
    )
    expect(WorkflowWorkspace).to receive(:cleanup_for).with(old)
    described_class.perform_now
  end

  it "db_sweep leaves succeeded workflows inside the short retention window alone" do
    recent = make_workflow(state: "succeeded", finished_at: 1.minute.ago)
    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(recent)
    described_class.perform_now
  end

  it "db_sweep preserves succeeded workflows while a run is awaiting operator input" do
    wf = make_workflow(
      state: "succeeded",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.minute).ago
    )
    step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "running")
    Run.create!(job: wf.job, step: step, trigger_kind: "initial", state: "awaiting_operator")

    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(wf)
    described_class.perform_now
  end

  # ---- db_sweep: failed uses long retention -----------------------

  it "db_sweep cleans failed workflows past RETAIN_AFTER_FAILURE" do
    old = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_FAILURE + 1.day).ago
    )
    expect(WorkflowWorkspace).to receive(:cleanup_for).with(old)
    described_class.perform_now
  end

  it "db_sweep does not clean failed workflows inside RETAIN_AFTER_FAILURE (retry window)" do
    recent = make_workflow(state: "failed", finished_at: 1.hour.ago)
    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(recent)
    described_class.perform_now
  end

  it "db_sweep does not clean failed workflows that finished after succeeded short-window but before failure long-window" do
    mid = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.hour).ago
    )
    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(mid)
    described_class.perform_now
  end

  it "db_sweep skips already-cleaned-up workflows" do
    already = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_FAILURE + 1.day).ago,
      cleaned_up_at: 1.day.ago
    )
    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(already)
    described_class.perform_now
  end

  it "db_sweep skips active workflows even if they're old" do
    active = make_workflow(state: "running", finished_at: nil)
    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(active)
    described_class.perform_now
  end

  it "db_sweep preserves failed workflows while a run is awaiting operator input" do
    wf = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_FAILURE + 1.day).ago
    )
    step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "running")
    Run.create!(job: wf.job, step: step, trigger_kind: "initial", state: "awaiting_operator")

    expect(WorkflowWorkspace).not_to receive(:cleanup_for).with(wf)
    described_class.perform_now
  end

  # ---- filesystem_sweep -------------------------------------------

  # For filesystem_sweep tests we need real disk state, so un-stub
  # WorkflowWorkspace.cleanup_for for the examples below.

  it "filesystem_sweep removes a directory whose Workflow no longer exists in the DB" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original

    orphan_path = Pathname.new(data_root).join("workflows", "99999999")
    FileUtils.mkdir_p(orphan_path.to_s)

    described_class.perform_now

    expect(orphan_path).not_to exist
  end

  it "filesystem_sweep removes a succeeded workflow dir past the short retention" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original

    wf = make_workflow(
      state: "succeeded",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.minute).ago
    )
    wf_path = Pathname.new(data_root).join("workflows", wf.id.to_s)
    FileUtils.mkdir_p(wf_path.to_s)

    described_class.perform_now

    expect(wf_path).not_to exist
    expect(wf.reload.cleaned_up_at).to be_present
  end

  it "filesystem_sweep leaves a failed workflow dir inside the retry retention window" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original

    wf = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_SUCCESS_OR_CANCEL + 1.hour).ago
    )
    wf_path = Pathname.new(data_root).join("workflows", wf.id.to_s)
    FileUtils.mkdir_p(wf_path.to_s)

    described_class.perform_now

    expect(wf_path).to exist
  end

  it "filesystem_sweep preserves a failed workflow dir while a run is awaiting operator input" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original

    wf = make_workflow(
      state: "failed",
      finished_at: (described_class::RETAIN_AFTER_FAILURE + 1.day).ago
    )
    step = Step.create!(workflow: wf, kind: "implement", position: 0, state: "running")
    Run.create!(job: wf.job, step: step, trigger_kind: "initial", state: "awaiting_operator")
    wf_path = Pathname.new(data_root).join("workflows", wf.id.to_s)
    FileUtils.mkdir_p(wf_path.to_s)

    described_class.perform_now

    expect(wf_path).to exist
    expect(wf.reload.cleaned_up_at).to be_nil
  end

  it "filesystem_sweep is a no-op when the workflows/ dir does not exist" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original
    # data_root has no workflows/ subdir — should not raise
    expect { described_class.perform_now }.not_to raise_error
  end

  it "is a no-op when nothing is prunable" do
    make_workflow(state: "failed", finished_at: 1.hour.ago)
    expect(WorkflowWorkspace).not_to receive(:cleanup_for)
    described_class.perform_now
  end

  it "prunes chat workspaces idle past the retention window" do
    allow(WorkflowWorkspace).to receive(:cleanup_for).and_call_original
    chat = ChatSession.create!(user: Factories.user, last_message_at: (described_class::RETAIN_CHAT_WORKSPACES + 1.day).ago)
    path = ChatWorkspace.ensure_root!(chat)
    chat.update_columns(last_message_at: (described_class::RETAIN_CHAT_WORKSPACES + 1.day).ago,
                        updated_at: (described_class::RETAIN_CHAT_WORKSPACES + 1.day).ago)

    described_class.perform_now

    expect(path).not_to exist
    expect(chat.reload.workspace_path).to be_nil
  end
end
