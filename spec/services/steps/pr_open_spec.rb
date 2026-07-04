require "rails_helper"

RSpec.describe Steps::PrOpen do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "retry", agent_provider: workflow_provider) }
  let(:workflow_provider) { "claude" }
  let!(:implement_step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:pr_open_step) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  def composed_body_for(provider:, turns:)
    Run.create!(
      job: job,
      step: implement_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: provider,
      agent_turns: turns
    )
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )

    described_class.new(pr_open_run).send(:compose_body, "Body")
  end

  it "includes the authoring agent and turn count for Claude-authored PRs" do
    body = composed_body_for(provider: "claude", turns: 7)

    expect(body).to include("*Authored by Claude (Run took 7 turn(s), trigger=retry). Review carefully.*")
  end

  it "includes the authoring agent but omits turn count for Codex-authored PRs" do
    body = composed_body_for(provider: "codex", turns: 1)

    expect(body).to include("*Authored by Codex (trigger=retry). Review carefully.*")
    expect(body).not_to include("Run took")
  end

  it "appends a Test Plan section with a checkout command when the workflow has a test_plan artifact" do
    workflow.set_artifact!("test_plan", {
      steps: [ "Run bin/rspec spec/services/steps/pr_open_spec.rb", "Open /jobs/42 and inspect the PR body." ],
      notes: "Exercise the artifact-backed PR copy path."
    })

    body = composed_body_for(provider: "codex", turns: 1)

    expect(body).to include(<<~MARKDOWN.strip)
      ## Test Plan

      ```sh
      syrus checkout #{job.slug}
      ```
    MARKDOWN
    expect(body).to include("- Run bin/rspec spec/services/steps/pr_open_spec.rb")
    expect(body).to include("- Open /jobs/42 and inspect the PR body.")
    expect(body).to include("Exercise the artifact-backed PR copy path.")
  end

  it "includes a Latin Publilius Syrus blockquote in the composed body" do
    body = composed_body_for(provider: "claude", turns: 3)

    expect(body).to match(/^> \*"[^"]+"/)
    expect(body).to include("[Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus)")
  end

  it "places the Latin quote immediately before the --- separator" do
    body = composed_body_for(provider: "claude", turns: 3)

    lines = body.lines.map(&:chomp)
    separator_index = lines.index("---")
    expect(separator_index).to be_present
    quote_line = lines[0...separator_index].reverse.find { |l| l.start_with?(">") }
    expect(quote_line).to match(/^> \*"[^"]+"/)
  end

  it "persists the Job's :implemented state after opening a new PR" do
    job.update!(state: "running")
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    handler = described_class.new(pr_open_run)
    workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-42-#{job.id}")
    fake_client = instance_double(GithubClient, access_token: "tok")
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:push_branch)
    allow(handler).to receive(:pr_title_and_body).and_return([ "T", "B" ])
    allow(GithubClient).to receive(:for).and_return(fake_client)
    opener = instance_double(PullRequestOpener, open: 100)
    allow(PullRequestOpener).to receive(:new).and_return(opener)

    handler.call

    expect(job.reload.state).to eq("implemented")
  end

  it "persists the Job's :implemented state on the idempotent retry path (PR already exists)" do
    job.update!(state: "running", pr_number: 77)
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    handler = described_class.new(pr_open_run)
    workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-42-#{job.id}")
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:push_branch)
    expect(PullRequestOpener).not_to receive(:new)

    handler.call

    expect(job.reload.state).to eq("implemented")
  end

  it "passes the Job to PullRequestOpener so dependent PRs use their effective base" do
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    handler = described_class.new(pr_open_run)
    workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-42-#{job.id}")
    opener = instance_double(PullRequestOpener)
    client = instance_double(GithubClient, access_token: "tok")

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:push_branch)
    allow(handler).to receive(:pr_title_and_body).and_return([ "T", "B" ])
    allow(GithubClient).to receive(:for).with(repository: repository, user: job.user).and_return(client)
    expect(PullRequestOpener).to receive(:new).with(repository, client: client, head_repository: nil).and_return(opener)
    expect(opener).to receive(:open).with(
      branch: "syrus/issue-42-#{job.id}",
      title: "T",
      body: "B",
      job: job
    ).and_return(99)

    handler.call

    expect(job.reload.pr_number).to eq(99)
    expect(job.reload.pr_repository_id).to eq(repository.id)
  end

  context "when the Job has a cross-fork target_repository" do
    let(:upstream) { Factories.repository(user: user, owner: "upstream-org", name: "widgets") }
    let(:fork_job) do
      j = Factories.job(repository: repository, issue_number: 55, target_repository: upstream)
      j.update!(state: "running")
      j
    end
    let(:fork_workflow) { Workflow.create!(job: fork_job, trigger_kind: "initial", agent_provider: "claude") }
    let!(:fork_implement_step) { Step.create!(workflow: fork_workflow, kind: "implement", position: 0) }
    let!(:fork_pr_open_step) { Step.create!(workflow: fork_workflow, kind: "pr_open", position: 1) }

    it "opens PR on the upstream with the fork's owner in the head ref and saves pr_repository_id" do
      fork_run = Run.create!(
        job: fork_job,
        step: fork_pr_open_step,
        trigger_kind: fork_workflow.trigger_kind,
        agent_provider: fork_workflow.agent_provider
      )
      handler = described_class.new(fork_run)
      workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-55-#{fork_job.id}")
      upstream_client = instance_double(GithubClient, access_token: "upstream-tok")
      opener = instance_double(PullRequestOpener)

      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:push_branch)
      allow(handler).to receive(:pr_title_and_body).and_return([ "U", "V" ])
      allow(GithubClient).to receive(:for).with(repository: upstream, user: fork_job.user).and_return(upstream_client)
      expect(PullRequestOpener).to receive(:new).with(
        upstream,
        client: upstream_client,
        head_repository: repository
      ).and_return(opener)
      expect(opener).to receive(:open).with(
        branch: "syrus/issue-55-#{fork_job.id}",
        title: "U",
        body: "V",
        job: fork_job
      ).and_return(200)

      handler.call

      fork_job.reload
      expect(fork_job.pr_number).to eq(200)
      expect(fork_job.pr_repository_id).to eq(upstream.id)
    end
  end

  it "fails clearly when an existing PR branch moved before push" do
    job.update!(state: "running", pr_number: 77)
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    handler = described_class.new(pr_open_run)
    path = Pathname.new("/tmp/syrus-pr-open-spec")
    workspace = instance_double(WorkflowWorkspace, branch_name: "syrus/issue-42-#{job.id}", path: path)
    client = instance_double(GithubClient, access_token: "token")
    git = instance_double(GitRunner)
    push_url = repository.authenticated_push_url("token")

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).with(repository: repository, user: job.user).and_return(client)
    allow(git).to receive(:run).with(
      "fetch",
      push_url,
      "+refs/heads/syrus/issue-42-#{job.id}:refs/remotes/origin/syrus/issue-42-#{job.id}",
      chdir: path.to_s
    ).and_return("")
    allow(git).to receive(:run)
      .with("rev-parse", "refs/remotes/origin/syrus/issue-42-#{job.id}", chdir: path.to_s)
      .and_return("remote-sha\n")
    allow(git).to receive(:run)
      .with("rev-parse", "HEAD", chdir: path.to_s)
      .and_return("local-sha\n")
    allow(git).to receive(:run)
      .with("merge-base", "--is-ancestor", "remote-sha", "HEAD", chdir: path.to_s)
      .and_raise(GitRunner::GitError.new([ "merge-base" ], 1, "not ancestor"))

    expect {
      handler.send(:push_branch)
    }.to raise_error(Steps::PrOpen::BranchDiverged, /PR branch changed before Syrus could push/)

    artifact = workflow.reload.artifact("branch_divergence")
    expect(artifact).to include(
      "branch" => "syrus/issue-42-#{job.id}",
      "remote_sha" => "remote-sha",
      "local_sha" => "local-sha",
      "message" => "remote PR branch moved before push"
    )
    expect(git).not_to have_received(:run).with("push", anything, anything, chdir: anything)
  end

  context "when falling back to the second-shot summarizer" do
    let(:user) { Factories.user(agent_provider: "codex", codex_api_key: "sk-test") }
    let(:workflow_provider) { "codex" }

    it "passes the active provider adapter instead of Claude credentials" do
      Run.create!(
        job: job,
        step: implement_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: "codex",
        agent_diff: "diff --git a/feature.rb b/feature.rb\n+def x = 1\n"
      )
      pr_open_run = Run.create!(
        job: job,
        step: pr_open_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: "codex"
      )
      handler = described_class.new(pr_open_run)
      allow(handler).to receive(:pr_summarizer_context)
        .and_return(Struct.new(:title, :body).new("Issue", "Body"))

      expect(PrSummarizer).to receive(:new) do |kwargs|
        expect(kwargs[:agent]).to be_a(AgentProviders::Codex)
        expect(kwargs).not_to have_key(:oauth_token)
        double(call: PrSummarizer::Result.new(title: "Fallback title", body: "Fallback body", error: nil))
      end

      expect(handler.send(:pr_title_and_body_from_summarizer))
        .to eq([ "Fallback title", "Fallback body" ])
    end
  end
end
