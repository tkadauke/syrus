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
    expect(PullRequestOpener).to receive(:new).with(repository, client: client).and_return(opener)
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

  context "for PR-mode reconciliation Jobs" do
    let(:epic) { Factories.epic(user: user, repository: repository, state: "in_progress", reconciliation_mode: "pr") }
    let(:parent_job) do
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        issue_number: 40,
        state: "implemented",
        branch_name: "syrus/direct-parent",
        pr_number: 40
      )
    end
    let(:job) do
      Factories.job_record(
        user: user,
        repository: repository,
        epic: epic,
        kind: "direct",
        issue_number: nil,
        issue_title: "Reconciliation: #{epic.title}",
        state: "running"
      )
    end

    around do |example|
      Dir.mktmpdir("syrus-reconciliation-pr-open") do |dir|
        @git_dir = Pathname.new(dir)
        example.run
      end
    end

    def git(*args)
      system("git", *args.map(&:to_s), chdir: @git_dir.to_s, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
    end

    def commit(message)
      git("add", ".")
      git("commit", "-m", message)
    end

    def prepare_reconciliation_repo(extra_reconciliation_change: false)
      git("init", "-b", "main")
      git("config", "user.name", "Spec")
      git("config", "user.email", "spec@example.com")
      @git_dir.join("feature.txt").write("base\n")
      commit("base")

      git("checkout", "-b", "stack-parent")
      @git_dir.join("feature.txt").write("parent\n")
      commit("parent patch")

      git("checkout", "main")
      git("checkout", "-b", "reconciliation")
      @git_dir.join("feature.txt").write("parent\n")
      @git_dir.join("reconciliation.txt").write("extra\n") if extra_reconciliation_change
      commit("reconciliation patch")
    end

    def run_reconciliation_pr_open
      JobDependency.create!(job: job, depends_on_job: parent_job, source: "manual", created_by_user: user)
      epic.update!(reconciliation_job_id: job.id)
      pr_open_run = Run.create!(
        job: job,
        step: pr_open_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider
      )
      handler = described_class.new(pr_open_run)
      workspace = instance_double(
        WorkflowWorkspace,
        setup: true,
        branch_name: "syrus/direct-reconciliation",
        path: @git_dir,
        base_ref: "origin/main"
      )
      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:streaming_git).and_return(GitRunner.new)
      allow(handler).to receive(:reconciliation_comparison_ref).and_return("stack-parent")
      handler
    end

    it "closes as no_changes without opening a PR when the branch tree matches the effective stack parent" do
      prepare_reconciliation_repo
      handler = run_reconciliation_pr_open

      expect(handler).not_to receive(:push_branch)
      expect(PullRequestOpener).not_to receive(:new)

      handler.call

      job.reload
      expect(job).to be_closed
      expect(job.closure_reason).to eq("no_changes")
      expect(job.pr_number).to be_nil
      expect(workflow.reload.artifact("no_pr_reason")).to include(
        "kind" => "empty_reconciliation",
        "base_branch" => "syrus/direct-parent"
      )
    end

    it "opens a PR when reconciliation adds changes beyond the effective stack parent" do
      prepare_reconciliation_repo(extra_reconciliation_change: true)
      handler = run_reconciliation_pr_open
      fake_client = instance_double(GithubClient, access_token: "tok")
      opener = instance_double(PullRequestOpener, open: 88)

      allow(handler).to receive(:push_branch)
      allow(handler).to receive(:pr_title_and_body).and_return([ "Reconcile stack", "Body" ])
      allow(GithubClient).to receive(:for).with(repository: repository, user: job.user).and_return(fake_client)
      expect(PullRequestOpener).to receive(:new).with(repository, client: fake_client).and_return(opener)

      handler.call

      expect(job.reload.pr_number).to eq(88)
      expect(job).to be_implemented
    end

    it "comments on and closes an already-open empty reconciliation PR" do
      prepare_reconciliation_repo
      job.update!(pr_number: 91, pr_repository: repository)
      handler = run_reconciliation_pr_open
      fake_client = instance_double(GithubClient)

      allow(GithubClient).to receive(:for).with(repository: repository, user: job.user).and_return(fake_client)
      expect(fake_client).to receive(:add_issue_comment).with(
        repository.slug,
        91,
        a_string_including("no diff against the effective stack parent")
      )
      expect(fake_client).to receive(:close_pull_request).with(repository.slug, 91)
      expect(handler).not_to receive(:push_branch)

      handler.call

      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("no_changes")
    end
  end

  context "when the Job has a cross-fork target_repository (fork review mode)" do
    let(:upstream) { Factories.repository(user: user, owner: "upstream-org", name: "widgets") }
    let(:fork_job) do
      j = Factories.job(repository: repository, issue_number: 55, target_repository: upstream)
      j.update!(state: "running")
      j
    end
    let(:fork_workflow) { Workflow.create!(job: fork_job, trigger_kind: "initial", agent_provider: "claude") }
    let!(:fork_implement_step) { Step.create!(workflow: fork_workflow, kind: "implement", position: 0) }
    let!(:fork_pr_open_step) { Step.create!(workflow: fork_workflow, kind: "pr_open", position: 1) }

    it "opens a fork review PR on the fork (not the upstream) and saves fork_review_pr_number" do
      fork_run = Run.create!(
        job: fork_job,
        step: fork_pr_open_step,
        trigger_kind: fork_workflow.trigger_kind,
        agent_provider: fork_workflow.agent_provider
      )
      handler = described_class.new(fork_run)
      workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-55-#{fork_job.id}")
      fork_client = instance_double(GithubClient, access_token: "fork-tok")
      opener = instance_double(PullRequestOpener)

      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:push_branch)
      allow(handler).to receive(:pr_title_and_body).and_return([ "Add greeting", "Body text" ])
      allow(GithubClient).to receive(:for).with(repository: repository, user: fork_job.user).and_return(fork_client)
      expect(PullRequestOpener).to receive(:new).with(repository, client: fork_client).and_return(opener)
      expect(opener).to receive(:open).with(
        branch: "syrus/issue-55-#{fork_job.id}",
        title: "[Review] Add greeting — approve to send to upstream-org/#{upstream.name}",
        body: a_string_including("Staging review", "upstream-org/#{upstream.name}", "Body text"),
        job: fork_job
      ).and_return(201)

      handler.call

      fork_job.reload
      expect(fork_job.fork_review_pr_number).to eq(201)
      expect(fork_job.pr_number).to be_nil
      expect(fork_job.pr_repository_id).to be_nil
      expect(fork_job.state).to eq("implemented")
    end

    it "is idempotent when the fork review PR already exists" do
      fork_job.update!(fork_review_pr_number: 99)
      fork_run = Run.create!(
        job: fork_job,
        step: fork_pr_open_step,
        trigger_kind: fork_workflow.trigger_kind,
        agent_provider: fork_workflow.agent_provider
      )
      handler = described_class.new(fork_run)
      workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-55-#{fork_job.id}")
      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:push_branch)
      expect(PullRequestOpener).not_to receive(:new)

      handler.call

      expect(fork_job.reload.fork_review_pr_number).to eq(99)
      expect(fork_job.reload.state).to eq("implemented")
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

  context "for coding handoff workflows" do
    let(:workflow) do
      Workflow.create!(
        job: job,
        trigger_kind: "coding_handoff",
        agent_provider: workflow_provider,
        artifacts: {
          "coding_handoff" => {
            "handoff_branch" => "syrus/chat-1-handoff-99",
            "head_sha" => "expected-sha"
          },
          "pr_title" => "Captured title",
          "pr_body" => "Captured body",
          "test_plan" => { "steps" => [], "notes" => nil }
        }
      )
    end

    it "refuses to open a PR when the checkout is not the captured handoff commit" do
      pr_open_run = Run.create!(
        job: job,
        step: pr_open_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider
      )
      handler = described_class.new(pr_open_run)
      workspace = instance_double(
        WorkflowWorkspace,
        setup: true,
        branch_name: "syrus/chat-1-handoff-99",
        path: Pathname.new("/tmp/syrus-coding-handoff"),
        base_ref: "origin/main"
      )
      git = instance_double(GitRunner)

      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:streaming_git).and_return(git)
      allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/syrus-coding-handoff").and_return("actual-sha\n")

      expect(handler).not_to receive(:push_branch)
      expect {
        handler.call
      }.to raise_error(Steps::Base::StepFailed, /checkout is stale/)
    end

    it "refuses to open a PR when the captured handoff commit has no diff against base" do
      pr_open_run = Run.create!(
        job: job,
        step: pr_open_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider
      )
      handler = described_class.new(pr_open_run)
      workspace = instance_double(
        WorkflowWorkspace,
        setup: true,
        branch_name: "syrus/chat-1-handoff-99",
        path: Pathname.new("/tmp/syrus-coding-handoff"),
        base_ref: "origin/main"
      )
      git = instance_double(GitRunner)

      allow(handler).to receive(:workspace).and_return(workspace)
      allow(handler).to receive(:streaming_git).and_return(git)
      allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/syrus-coding-handoff").and_return("expected-sha\n")
      allow(git).to receive(:run).with("diff", "--name-only", "origin/main...HEAD", chdir: "/tmp/syrus-coding-handoff").and_return("\n")

      expect(handler).not_to receive(:push_branch)
      expect {
        handler.call
      }.to raise_error(Steps::Base::StepFailed, /no changes/)
    end
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
