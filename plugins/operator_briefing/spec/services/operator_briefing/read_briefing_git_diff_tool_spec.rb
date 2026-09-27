require "rails_helper"

RSpec.describe OperatorBriefing::Tools::ReadBriefingGitDiffTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_with_run(user: user, repository: repository) }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first }
  let(:window_start) { 2.days.ago.change(usec: 0) }
  let(:window_end) { 1.hour.ago.change(usec: 0) }
  let!(:briefing) do
    OperatorBriefing::Briefing.create!(
      job: job,
      repository: repository,
      owner_user: user,
      window_start: window_start,
      window_end: window_end
    )
  end
  let(:workspace_path) { Rails.root.join("tmp", "operator-briefing-diff-spec") }
  let(:workspace) { instance_double(WorkflowWorkspace, path: workspace_path) }
  let(:git) { instance_double(GitRunner) }

  before do
    PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
    Feature.clear_enabled_cache!("operator_briefing")
    allow(StepWorkspace).to receive(:for).with(step, run: run).and_return(workspace)
    allow(GitRunner).to receive(:new).and_return(git)
  end

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "reads patch output for the briefing window and optional path" do
    allow(git).to receive(:run).and_return("commit abc123\n+changed CODEX_API_KEY=sk-secret-value-abcdefghijklmnop")

    response = described_class.call(
      server_context: { run: run },
      path: "app/models/user.rb",
      max_bytes: 4_000
    )

    expect(response).not_to be_error, response.content.first[:text]
    expect(git).to have_received(:run).with(
      "log",
      "--since=#{window_start.iso8601}",
      "--until=#{window_end.iso8601}",
      "--patch",
      "--stat",
      "--find-renames",
      "--no-ext-diff",
      "--",
      "app/models/user.rb",
      chdir: workspace_path.to_s
    )
    expect(payload(response)).to include(
      repository: { id: repository.id, slug: repository.slug },
      window_start: window_start.iso8601,
      window_end: window_end.iso8601,
      path: "app/models/user.rb",
      truncated: false
    )
    expect(payload(response)[:patch]).to include("[REDACTED]")
    expect(payload(response)[:patch]).not_to include("sk-secret-value-abcdefghijklmnop")
  end

  it "caps payloads at the requested bounded byte limit" do
    allow(git).to receive(:run).and_return("x" * 1_500)

    response = described_class.call(server_context: { run: run }, max_bytes: 1_000)

    expect(response).not_to be_error, response.content.first[:text]
    result = payload(response)
    expect(result[:truncated]).to be(true)
    expect(result[:patch].bytesize).to eq(1_000)
  end

  it "returns a tool error when git cannot produce the diff" do
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new([ "log", "--patch" ], 128, "fatal: not a git repository")
    )

    response = described_class.call(server_context: { run: run })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("git diff unavailable")
    expect(response.content.first[:text]).to include("fatal: not a git repository")
  end
end
