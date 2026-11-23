require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RunJob, "browser pre-admission", :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    AppSetting.current.update!(workflow_admission_control_enabled: true)
    @data_root = Dir.mktmpdir("syrus-browser-run-job")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(@data_root)
  end

  it "skips a no-match visual review before host admission under critical worker pressure" do
    job, workflow, step, run = visual_review_run
    initialize_workspace_repo(
      workflow,
      ".syrus.yml" => visual_review_config("app/frontend/**"),
      "lib/backend.rb" => "class Backend; end\n"
    )
    record_critical_worker_pressure!
    expect(RunHostAdmission).not_to receive(:call)

    expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)

    expect(run.reload).to be_succeeded
    expect(step.reload).to be_succeeded
    expect(step.details).to include("skipped" => true, "skip_reason" => "visual_review_when_files_changed_no_match")
    expect(workflow.reload.artifact("visual_review_iterations")).to eq([
      {
        "iteration" => 1,
        "step_id" => step.id,
        "run_id" => run.id,
        "critique" => "No changed files matched the configured visual_review.when_files_changed patterns.",
        "verdict" => "skipped"
      }
    ])
    expect(workflow.artifact("run_host_admission")).to be_nil
    expect(JobLog.where(run: run).pluck(:chunk).grep(/compute host admission deferred/)).to be_empty
  end

  it "skips a nested visual review before host admission without a root config" do
    _job, workflow, step, run = visual_review_run
    initialize_workspace_repo(
      workflow,
      "apps/web/.syrus.yml" => <<~YAML,
        project:
          id: web
        preview:
          start: npm run dev
        #{visual_review_config("src/**")}
      YAML
      "docs/readme.md" => "docs only\n"
    )
    record_critical_worker_pressure!
    expect(RunHostAdmission).not_to receive(:call)

    expect { described_class.perform_now(run.id) }.not_to have_enqueued_job(described_class)

    expect(run.reload).to be_succeeded
    expect(step.reload.details).to include("skipped" => true, "skip_reason" => "visual_review_when_files_changed_no_match")
    expect(workflow.reload.artifact("run_host_admission")).to be_nil
  end

  it "admits visual review when the cumulative workspace diff matches" do
    job, workflow, step, run = visual_review_run
    implement = workflow.steps.create!(kind: "implement", position: 0, state: "succeeded")
    implement.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: job.agent_provider,
      state: "succeeded",
      step_agent_diff: "diff --git a/docs/readme.md b/docs/readme.md\n+docs only\n"
    )
    initialize_workspace_repo(
      workflow,
      ".syrus.yml" => visual_review_config("app/frontend/**"),
      "app/frontend/routes/card.tsx" => "export const card = true\n"
    )
    decision = RunHostAdmission::Decision.new(
      action: "defer", reason: "local_worker_pressure_critical", delay: 30.seconds,
      details: { "hostname" => "worker-a" }
    )
    allow(RunHostAdmission).to receive(:call).with(run: run, queue_name: "runs").and_return(decision)

    expect { described_class.perform_now(run.id) }.to have_enqueued_job(described_class).with(run.id).on_queue("runs")

    expect(run.reload).to be_queued
    expect(step.reload.details).not_to include("skip_reason" => "visual_review_when_files_changed_no_match")
    expect(workflow.reload.artifact("visual_review_iterations")).to be_nil
    expect(workflow.artifact("run_host_admission")).to include(
      "action" => "defer", "reason" => "local_worker_pressure_critical"
    )
  end

  private

  def visual_review_run
    job = Factories.job_with_run(
      user: user,
      repository: repository,
      state: "queued",
      workflow_attrs: { trigger_kind: "manual" },
      step_attrs: { kind: "visual_review" },
      run_attrs: { trigger_kind: "manual" }
    )
    workflow = job.workflows.last
    step = workflow.first_step
    [ job, workflow, step, step.runs.first ]
  end

  def visual_review_config(pattern)
    <<~YAML
      visual_review:
        enabled: true
        when_files_changed:
          - "#{pattern}"
    YAML
  end

  def initialize_workspace_repo(workflow, files)
    path = WorkflowWorkspace.path_for(workflow)
    FileUtils.mkdir_p(path)
    system("git", "init", "-q", "-b", "main", path.to_s, exception: true)
    system("git", "-C", path.to_s, "config", "user.email", "test@example.com", exception: true)
    system("git", "-C", path.to_s, "config", "user.name", "Test", exception: true)
    File.write(path.join("README.md"), "seed\n")
    system("git", "-C", path.to_s, "add", "README.md", exception: true)
    system("git", "-C", path.to_s, "commit", "-q", "-m", "initial", exception: true)
    system("git", "-C", path.to_s, "remote", "add", "origin", path.to_s, exception: true)
    system("git", "-C", path.to_s, "fetch", "-q", "origin", "main:refs/remotes/origin/main", exception: true)
    branch_name = workflow.job.branch_name || "syrus/direct-#{workflow.job.id}"
    system("git", "-C", path.to_s, "checkout", "-q", "-b", branch_name, exception: true)
    files.each do |relative_path, content|
      full_path = path.join(relative_path)
      FileUtils.mkdir_p(full_path.dirname)
      File.write(full_path, content)
      system("git", "-C", path.to_s, "add", relative_path, exception: true)
    end
    system("git", "-C", path.to_s, "commit", "-q", "-m", "feature changes", exception: true)
  end

  def record_critical_worker_pressure!
    WorkerHostHealthSample.create!(
      hostname: SyrusVersion.hostname,
      role: "worker",
      version: "test",
      observed_at: Time.current,
      raw_metrics: {},
      cpu_pressure_some: 95.0,
      cpu_pressure_full: 80.0,
      io_pressure_some: 10.0,
      io_pressure_full: 5.0,
      memory_used_percent: 98.0
    )
  end
end
