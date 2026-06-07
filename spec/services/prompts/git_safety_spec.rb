require "rails_helper"

RSpec.describe Prompts::GitSafety do
  it "briefly explains Syrus and repo setup" do
    text = described_class::TEXT
    expect(text).to include("Syrus is the automation harness")
    expect(text).to include("GitHub issues, PR")
    expect(text).to include("scheduled tasks")
    expect(text).to include("`.syrus.yml`")
    expect(text).to include("prepare:")
    expect(text).to include("auto-detects one setup command")
  end

  it "names the destructive ops it forbids" do
    text = described_class::TEXT
    expect(text).to include("git checkout --orphan")
    expect(text).to include("git reset --hard")
    expect(text).to include("git rm -r .")
    expect(text).to include("git update-ref")
  end

  it "explains the pipeline contract" do
    expect(described_class::TEXT).to include("git diff origin/<default_branch>...HEAD")
  end

  it "tells agents to read live Syrus state before operational claims" do
    text = described_class::TEXT
    expect(text).to include("read_live_state")
    expect(text).to include("current Job, Workflow, Run, queue, PR, or related chat state")
    expect(text).to include("Do not use it to mutate jobs or queues")
  end
end

# Defense-in-depth: every primary-agent prompt that runs the
# commit-and-push pipeline must include GitSafety::TEXT, otherwise
# the warning was never delivered to the agent.
RSpec.describe "primary-agent prompts include GitSafety::TEXT" do
  it "Initial" do
    issue = Struct.new(:title, :body).new("t", "b")
    expect(Prompts::Initial.new(issue: issue).to_s).to include(Prompts::GitSafety::TEXT)
  end

  it "PrFeedback" do
    issue = Struct.new(:title, :body).new("t", "b")
    expect(Prompts::PrFeedback.new(issue: issue, comments: []).to_s).to include(Prompts::GitSafety::TEXT)
  end

  it "Rebase" do
    expect(
      Prompts::Rebase.new(
        repo_slug: "acme/widgets", branch_name: "syrus/issue-1-1",
        base_branch: "main", pr_number: 99
      ).to_s
    ).to include(Prompts::GitSafety::TEXT)
  end

  it "ScheduledTask" do
    user = Factories.user
    repo = Factories.repository(user: user)
    task = ScheduledTask.create!(
      user: user, repository: repo,
      name: "t", prompt: "do a thing",
      kind: "cron", cron_expression: "0 9 * * 1", pr_pileup_policy: "skip"
    )
    expect(Prompts::ScheduledTask.new(scheduled_task: task).to_s).to include(Prompts::GitSafety::TEXT)
  end
end
