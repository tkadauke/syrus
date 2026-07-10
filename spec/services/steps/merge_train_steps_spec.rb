require "rails_helper"
require "ostruct"

RSpec.describe "Steps::MergeTrain*" do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def member_job(issue_number:, state: "landing")
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: state,
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  def build_train(members)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master",
                              integration_branch: "syrus/merge-train-epic-#{epic.id}-x")
    members.each_with_index { |job, i| MergeTrainMember.create!(merge_train: train, job: job, position: i) }
    train
  end

  def step_handler(klass, kind, train, owner_job)
    artifacts = { "merge_train_id" => train.id }
    artifacts["merge_train_base_sha"] = "basesha123" if kind == "merge_train_land"
    workflow = Workflow.create!(job: owner_job, trigger_kind: "merge_train", artifacts: artifacts)
    step = Step.create!(workflow: workflow, kind: kind, position: 0)
    run = Run.create!(job: owner_job, step: step, trigger_kind: "merge_train")
    klass.new(run)
  end

  def stub_git(handler, head: "intsha999", base: "basesha123")
    workspace = instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new("/tmp/ws"), branch_name: "x")
    git = instance_double(GitRunner)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/ws").and_return("#{head}\n")
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: "/tmp/ws").and_return("#{base}\n")
    git
  end

  def octokit_error(error_class, status:, message:)
    error_class.new(status: status, body: { message: message })
  end

  describe Steps::MergeTrainAssemble do
    it "validates members are landing and names the integration branch" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      [ a, b ].each_with_index { |j, i| MergeTrainMember.create!(merge_train: train, job: j, position: i) }

      step_handler(described_class, "merge_train_assemble", train, b).call

      expect(train.reload.integration_branch).to eq("syrus/merge-train-epic-#{epic.id}-#{train.id}")
    end

    it "fails when a member is not in :landing" do
      a = member_job(issue_number: 1, state: "approved")
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      MergeTrainMember.create!(merge_train: train, job: a, position: 0)

      expect { step_handler(described_class, "merge_train_assemble", train, a).call }
        .to raise_error(Steps::Base::StepFailed, /not in :landing/)
    end

    it "fails when an epic sibling is open but not yet approved" do
      a = member_job(issue_number: 1)
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      MergeTrainMember.create!(merge_train: train, job: a, position: 0)
      straggler = Factories.job_record(
        user: user, repository: repository, epic: epic,
        issue_number: 2, state: "running", pr_number: 502
      )

      expect { step_handler(described_class, "merge_train_assemble", train, a).call }
        .to raise_error(Steps::Base::StepFailed, /cannot assemble.*#{straggler.id}/)
    end

    it "does not block when the only non-member sibling is closed" do
      a = member_job(issue_number: 1)
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      MergeTrainMember.create!(merge_train: train, job: a, position: 0)
      Factories.job_record(
        user: user, repository: repository, epic: epic,
        issue_number: 2, state: "closed", pr_number: 502
      )

      expect { step_handler(described_class, "merge_train_assemble", train, a).call }.not_to raise_error
      expect(train.reload.integration_branch).to be_present
    end

    it "does not block when the only non-member sibling is approved (waiting for a future train)" do
      a = member_job(issue_number: 1)
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      MergeTrainMember.create!(merge_train: train, job: a, position: 0)
      Factories.job_record(
        user: user, repository: repository, epic: epic,
        issue_number: 2, state: "approved", pr_number: 502
      )

      expect { step_handler(described_class, "merge_train_assemble", train, a).call }.not_to raise_error
    end
  end

  describe Steps::MergeTrainBuild do
    let(:authenticated_fetch_url) { "https://token.example/acme/widgets.git" }

    before do
      client = instance_double(GithubClient, access_token: "ghs_train")
      allow(GithubClient).to receive(:for).and_return(client)
      allow_any_instance_of(Repository).to receive(:authenticated_push_url)
        .with("ghs_train")
        .and_return(authenticated_fetch_url)
    end

    it "rebases each member onto the integration tip (mechanically) and marks the train grading" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_build", train, b)
      git = stub_git(handler)
      allow(handler).to receive(:run_agent)

      handler.call

      expect(git).to have_received(:run).with("fetch", authenticated_fetch_url, "refs/heads/master", chdir: "/tmp/ws")
      expect(git).to have_received(:run).with("fetch", authenticated_fetch_url, "refs/heads/syrus/issue-1", chdir: "/tmp/ws")
      expect(git).to have_received(:run).with("fetch", authenticated_fetch_url, "refs/heads/syrus/issue-2", chdir: "/tmp/ws")
      expect(git).not_to have_received(:run).with("fetch", "origin", anything, any_args)
      expect(git).to have_received(:run).with("checkout", "-B", train.integration_branch, "FETCH_HEAD", chdir: "/tmp/ws")
      # Mechanical rebase per member; no agent on the clean path.
      expect(git).to have_received(:run).with("rebase", train.integration_branch, chdir: "/tmp/ws").twice
      expect(git).to have_received(:run).with("merge", "--ff-only", anything, chdir: "/tmp/ws").twice
      expect(handler).not_to have_received(:run_agent)
      expect(train.reload.state).to eq("grading")
      expect(train.integration_sha).to eq("intsha999")
      expect(handler.workflow.artifact("merge_train_base_sha")).to eq("basesha123")
    end

    it "refreshes the installation token and retries when GitHub rejects an authenticated fetch" do
      installation = Factories.installation(
        user: user,
        cached_token: "ghs_expired",
        cached_token_expires_at: 30.minutes.from_now
      )
      repository.update!(installation: installation)
      expired_client = instance_double(GithubClient, access_token: "ghs_expired")
      fresh_client = instance_double(GithubClient, access_token: "ghs_fresh")
      expired_url = "https://x-access-token:expired@github.com/acme/widgets.git"
      fresh_url = "https://x-access-token:fresh@github.com/acme/widgets.git"
      allow(GithubClient).to receive(:for).and_return(expired_client, fresh_client, fresh_client)
      allow(GithubClient).to receive(:active_installation_for)
        .with(repository: repository, user: user)
        .and_return(installation)
      allow_any_instance_of(Repository).to receive(:authenticated_push_url)
        .with("ghs_expired")
        .and_return(expired_url)
      allow_any_instance_of(Repository).to receive(:authenticated_push_url)
        .with("ghs_fresh")
        .and_return(fresh_url)

      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_build", train, a)
      git = stub_git(handler)
      allow(handler).to receive(:run_agent)
      auth_error = GitRunner::GitError.new(
        [ "fetch", expired_url, "refs/heads/master" ],
        128,
        "remote: Invalid username or token.\nfatal: Authentication failed for 'https://github.com/acme/widgets.git/'"
      )
      allow(git).to receive(:run)
        .with("fetch", expired_url, "refs/heads/master", chdir: "/tmp/ws")
        .and_raise(auth_error)

      handler.call

      expect(installation.reload.cached_token).to be_nil
      expect(git).to have_received(:run).with("fetch", expired_url, "refs/heads/master", chdir: "/tmp/ws").once
      expect(git).to have_received(:run).with("fetch", fresh_url, "refs/heads/master", chdir: "/tmp/ws").once
      expect(git).to have_received(:run).with("fetch", fresh_url, "refs/heads/syrus/issue-1", chdir: "/tmp/ws").once
      expect(train.reload.state).to eq("grading")
    end

    it "does not refresh the installation token for non-authenticated fetch failures" do
      stale_client = instance_double(GithubClient, access_token: "ghs_stale")
      stale_url = "https://x-access-token:stale@github.com/acme/widgets.git"
      allow(GithubClient).to receive(:for).and_return(stale_client)
      allow(GithubClient).to receive(:active_installation_for)
      allow_any_instance_of(Repository).to receive(:authenticated_push_url)
        .with("ghs_stale")
        .and_return(stale_url)

      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_build", train, a)
      git = stub_git(handler)
      fetch_error = GitRunner::GitError.new(
        [ "fetch", stale_url, "refs/heads/master" ],
        128,
        "fatal: couldn't find remote ref refs/heads/master"
      )
      allow(git).to receive(:run)
        .with("fetch", stale_url, "refs/heads/master", chdir: "/tmp/ws")
        .and_raise(fetch_error)

      expect { handler.call }.to raise_error(GitRunner::GitError, /couldn't find remote ref/)
      expect(GithubClient).not_to have_received(:active_installation_for)
    end

    it "skips prepare and graders when the built integration SHA already passed grading" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      prior = Workflow.create!(
        job: b,
        trigger_kind: "merge_train",
        artifacts: {
          LandingValidationCache::ARTIFACT_KEY => {
            "required_graders_passed" => true,
            "head_sha" => "intsha999"
          }
        }
      )
      Step.create!(workflow: prior, kind: "merge_train_land", position: 0)

      workflow = Workflows::MergeTrain.instantiate(job: b, artifacts: { "merge_train_id" => train.id })
      build_step = workflow.steps.find_by!(kind: "merge_train_build")
      run = Run.create!(job: b, step: build_step, trigger_kind: "merge_train")
      handler = described_class.new(run)
      git = stub_git(handler)
      allow(handler).to receive(:run_agent)

      handler.call

      expect(git).to have_received(:run).with("rebase", train.integration_branch, chdir: "/tmp/ws").twice
      expect(workflow.steps.order(:position).pluck(:kind, :state)).to include(
        [ "prepare", "cancelled" ],
        [ "grader_fanout", "cancelled" ],
        [ "grader_collect", "cancelled" ],
        [ "merge_train_land", "queued" ]
      )
      expect(train.reload.integration_sha).to eq("intsha999")
    end

    it "hands the in-progress rebase to the agent on conflict, then verifies by end-state and integrates" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_build", train, a)
      git = stub_git(handler)
      allow(git).to receive(:run)
        .with("rebase", train.integration_branch, chdir: "/tmp/ws")
        .and_raise(GitRunner::GitError.new([ "rebase" ], 1, "CONFLICT (content)"))
      # Agent completed: checkout of the scratch branch succeeds, clean
      # tree, integration is an ancestor (all default-stub success).
      allow(handler).to receive(:run_agent)

      handler.call

      expect(handler).to have_received(:run_agent).once
      # End-state verification, not rebase-internal refs.
      expect(git).not_to have_received(:run).with("rev-parse", "-q", "--verify", "REBASE_HEAD", chdir: "/tmp/ws")
      expect(git).to have_received(:run).with("checkout", "__mt_member_#{a.id}", chdir: "/tmp/ws")
      expect(git).to have_received(:run).with("merge-base", "--is-ancestor", train.integration_branch, "__mt_member_#{a.id}", chdir: "/tmp/ws")
      expect(train.reload.state).to eq("grading")
    end

    it "fails (and aborts) when the rebase is still mid-flight (scratch checkout refused)" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_build", train, a)
      git = stub_git(handler)
      allow(git).to receive(:run)
        .with("rebase", train.integration_branch, chdir: "/tmp/ws")
        .and_raise(GitRunner::GitError.new([ "rebase" ], 1, "CONFLICT (content)"))
      allow(git).to receive(:run)
        .with("checkout", "__mt_member_#{a.id}", chdir: "/tmp/ws")
        .and_raise(GitRunner::GitError.new([ "checkout" ], 1, "rebase in progress"))
      allow(handler).to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /was not completed/)
      expect(git).to have_received(:run).with("rebase", "--abort", chdir: "/tmp/ws")
      expect(train.reload.state).not_to eq("grading")
    end

    it "fails when the result was rebased onto the wrong base (integration not an ancestor)" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_build", train, a)
      git = stub_git(handler)
      allow(git).to receive(:run)
        .with("rebase", train.integration_branch, chdir: "/tmp/ws")
        .and_raise(GitRunner::GitError.new([ "rebase" ], 1, "CONFLICT (content)"))
      allow(git).to receive(:run)
        .with("merge-base", "--is-ancestor", train.integration_branch, "__mt_member_#{a.id}", chdir: "/tmp/ws")
        .and_raise(GitRunner::GitError.new([ "merge-base" ], 1, "not an ancestor"))
      allow(handler).to receive(:run_agent)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /not rebased onto the integration branch/)
      expect(train.reload.state).not_to eq("grading")
    end
  end

  describe Steps::MergeTrainLand do
    let(:client) { instance_double(GithubClient, access_token: "token") }

    before do
      allow(GithubClient).to receive(:for).and_return(client)
      allow(repository).to receive(:authenticated_push_url).and_return("https://push.example/repo.git")
      allow(client).to receive(:open_pull_request_for_head).and_return(nil)
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 777))
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
      allow(client).to receive(:add_issue_comment)
      allow(client).to receive(:close_pull_request)
      allow(client).to receive(:delete_branch).and_return(true)
    end

    it "opens + merges an integration PR atomically, closes member PRs, and marks Jobs merged" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_land", train, b)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)

      handler.call

      expect(client).to have_received(:create_pull_request)
        .with("acme/widgets", hash_including(base: "master", head: train.integration_branch))
      expect(client).to have_received(:merge_pull_request).with("acme/widgets", 777, hash_including(merge_method: "merge"))
      expect(client).to have_received(:close_pull_request).with("acme/widgets", a.pr_number)
      expect(client).to have_received(:close_pull_request).with("acme/widgets", b.pr_number)
      expect(a.reload).to be_closed
      expect(a.closure_reason).to eq("pr_merged")
      expect(b.reload).to be_closed
      expect(train.reload.state).to eq("succeeded")
      expect(train.members.pluck(:state).uniq).to eq([ "merged" ])
    end

    it "deletes the integration branch and each member branch after landing" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_land", train, b)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)

      handler.call

      expect(client).to have_received(:delete_branch).with("acme/widgets", train.integration_branch)
      expect(client).to have_received(:delete_branch).with("acme/widgets", a.branch_name)
      expect(client).to have_received(:delete_branch).with("acme/widgets", b.branch_name)
      expect(a.reload.branch_deleted_at).to be_present
      expect(b.reload.branch_deleted_at).to be_present
    end

    it "skips member branch deletion when branch_name is absent" do
      a = member_job(issue_number: 1)
      a.update!(branch_name: nil)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)

      handler.call

      expect(client).not_to have_received(:delete_branch).with("acme/widgets", nil)
      expect(a.reload.branch_deleted_at).to be_nil
    end

    it "does not fail a landed train when branch cleanup is left for later" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_land", train, b)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      allow(client).to receive(:delete_branch)
        .with("acme/widgets", train.integration_branch)
        .and_return(false)
      allow(client).to receive(:delete_branch)
        .with("acme/widgets", a.branch_name)
        .and_return(false)

      handler.call

      expect(train.reload.state).to eq("succeeded")
      expect(a.reload).to be_closed
      expect(a.branch_deleted_at).to be_nil
      expect(b.reload.branch_deleted_at).to be_present
    end

    it "does not fail a landed train when member PR cleanup fails" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_land", train, b)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      allow(client).to receive(:add_issue_comment)
        .with("acme/widgets", a.pr_number, anything)
        .and_raise(octokit_error(Octokit::ServerError, status: 504, message: "Gateway Timeout"))
      allow(client).to receive(:close_pull_request)
        .with("acme/widgets", b.pr_number)
        .and_raise(octokit_error(Octokit::ServerError, status: 504, message: "Gateway Timeout"))

      expect { handler.call }.not_to raise_error

      expect(train.reload.state).to eq("succeeded")
      expect(train.members.pluck(:state).uniq).to eq([ "merged" ])
      expect(a.reload).to be_closed
      expect(b.reload).to be_closed
    end

    it "fails landing when GitHub does not report the integration PR merged" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: false))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /did not report/)
      expect(a.reload).not_to be_closed
    end

    it "reuses an already-open integration PR on retry" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      existing_pr = OpenStruct.new(number: 888, state: "open")
      allow(client).to receive(:open_pull_request_for_head).and_return(existing_pr)

      handler.call

      expect(client).not_to have_received(:create_pull_request)
      expect(client).to have_received(:merge_pull_request).with("acme/widgets", 888, hash_including(merge_method: "merge"))
      expect(handler.workflow.artifact("merge_train_pr_number")).to eq(888)
    end

    it "recovers when GitHub reports the integration PR already exists during creation" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      existing_pr = OpenStruct.new(number: 888, state: "open")
      allow(client).to receive(:open_pull_request_for_head).and_return(nil, existing_pr)
      allow(client).to receive(:create_pull_request)
        .and_raise(Octokit::UnprocessableEntity.new(status: 422, body: { message: "A pull request already exists" }))

      handler.call

      expect(client).to have_received(:create_pull_request)
      expect(client).to have_received(:merge_pull_request).with("acme/widgets", 888, hash_including(merge_method: "merge"))
      expect(handler.workflow.artifact("merge_train_pr_number")).to eq(888)
    end

    it "fails before pushing when the base branch moved after the train was built" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      handler.workflow.set_artifact!("merge_train_base_sha", "oldbase111")
      allow(handler).to receive(:repository).and_return(repository)
      git = stub_git(handler, base: "newbase222")

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /base moved .* rebuild required/)
      expect(git).to have_received(:run).with("fetch", "https://push.example/repo.git", "refs/heads/master", chdir: "/tmp/ws")
      expect(git).not_to have_received(:run).with("push", anything, any_args)
      expect(client).not_to have_received(:create_pull_request)
      expect(handler.workflow.artifact("merge_train_stale_base")).to include(
        "built_base_sha" => "oldbase111",
        "current_base_sha" => "newbase222"
      )
    end

    it "fails before pushing when an old land workflow has no recorded base SHA" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      handler.workflow.update!(artifacts: { "merge_train_id" => train.id })
      allow(handler).to receive(:repository).and_return(repository)
      git = stub_git(handler, base: "currentbase333")

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /missing built base SHA; rebuild required/)
      expect(git).to have_received(:run).with("fetch", "https://push.example/repo.git", "refs/heads/master", chdir: "/tmp/ws")
      expect(git).not_to have_received(:run).with("push", anything, any_args)
      expect(client).not_to have_received(:create_pull_request)
      expect(handler.workflow.artifact("merge_train_stale_base")).to include(
        "built_base_sha" => nil,
        "current_base_sha" => "currentbase333",
        "reason" => "missing_built_base_sha"
      )
    end

    it "closes the integration PR and fails genuinely when GitHub refuses a same-base merge" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      allow(handler).to receive(:repository).and_return(repository)
      stub_git(handler)
      allow(client).to receive(:merge_pull_request)
        .and_raise(octokit_error(Octokit::MethodNotAllowed, status: 405, message: "Pull Request has merge conflicts"))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /integration PR has merge conflicts/)
      expect(client).to have_received(:create_pull_request)
      expect(client).to have_received(:add_issue_comment).with("acme/widgets", 777, include("could not be merged cleanly"))
      expect(client).to have_received(:close_pull_request).with("acme/widgets", 777)
      expect(handler.workflow.artifact("merge_train_stale_base")).to be_nil
      expect(a.reload).not_to be_closed
    end

    it "closes the integration PR and requests a rebuild when GitHub refuses after the base moved" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      handler = step_handler(described_class, "merge_train_land", train, a)
      handler.workflow.set_artifact!("merge_train_base_sha", "oldbase111")
      allow(handler).to receive(:repository).and_return(repository)
      git = stub_git(handler, base: "oldbase111")
      allow(git).to receive(:run)
        .with("rev-parse", "FETCH_HEAD", chdir: "/tmp/ws")
        .and_return("oldbase111\n", "newbase222\n")
      allow(client).to receive(:merge_pull_request)
        .and_raise(octokit_error(Octokit::MethodNotAllowed, status: 405, message: "Pull Request has merge conflicts"))

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /base moved .* rebuild required/)
      expect(client).to have_received(:add_issue_comment).with("acme/widgets", 777, include("moved while this train was landing"))
      expect(client).to have_received(:close_pull_request).with("acme/widgets", 777)
      expect(handler.workflow.artifact("merge_train_stale_base")).to include(
        "built_base_sha" => "oldbase111",
        "current_base_sha" => "newbase222",
        "reason" => "base_moved"
      )
    end
  end

  describe MergeTrainFailureHandler do
    def train_with_workflow(members, reason:, artifacts: {})
      train = build_train(members)
      workflow = Workflow.create!(
        job: members.last,
        trigger_kind: "merge_train",
        artifacts: { "merge_train_id" => train.id }.merge(artifacts),
        failure_reason: reason
      )
      [ train, workflow ]
    end

    def train_with_workflow_and_failed_run(members, error_message:)
      train = build_train(members)
      workflow = Workflow.create!(
        job: members.last,
        trigger_kind: "merge_train",
        artifacts: { "merge_train_id" => train.id }
      )
      step = Step.create!(workflow: workflow, kind: "merge_train_land", position: 0)
      run = Run.create!(job: members.last, step: step, trigger_kind: "merge_train", state: "failed",
                        started_at: 5.minutes.ago, finished_at: 1.minute.ago)
      RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: error_message)
      [ train, workflow ]
    end

    it "fail_lands members (requires re-approval) on a genuine failure" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train, workflow = train_with_workflow([ a, b ], reason: "loop_exhausted_after_grader_failure")

      described_class.call(workflow: workflow)

      expect(a.reload.state).to eq("implemented")
      expect(b.reload.state).to eq("implemented")
      expect(train.reload.state).to eq("failed")
      expect(train.members.pluck(:state).uniq).to eq([ "failed" ])
    end

    it "defer_lands members (auto-retry) on a transient infrastructure blocker" do
      a = member_job(issue_number: 1)
      train, workflow = train_with_workflow([ a ], reason: "No space left on device")

      described_class.call(workflow: workflow)

      expect(a.reload.state).to eq("approved")
      expect(train.reload.state).to eq("failed")
    end

    it "defer_lands members when the merge-train base moved and needs rebuilding" do
      a = member_job(issue_number: 1)
      train, workflow = train_with_workflow([ a ], reason: "merge_train: base moved from oldbase to newbase; rebuild required")

      described_class.call(workflow: workflow)

      expect(a.reload.state).to eq("approved")
      expect(train.reload.state).to eq("failed")
    end

    it "defer_lands members when an old merge-train land workflow needs rebuilding" do
      a = member_job(issue_number: 1)
      train, workflow = train_with_workflow([ a ], reason: "merge_train: missing built base SHA; rebuild required")

      described_class.call(workflow: workflow)

      expect(a.reload.state).to eq("approved")
      expect(train.reload.state).to eq("failed")
    end

    context "when workflow.failure_reason is blank — stale-base artifact fallback" do
      it "defer_lands members when stale-base artifact records base_moved (not fail_lands)" do
        a = member_job(issue_number: 1)
        train, workflow = train_with_workflow(
          [ a ],
          reason: nil,
          artifacts: {
            "merge_train_stale_base" => {
              "base_branch" => "main",
              "built_base_sha" => "abc123456789000",
              "current_base_sha" => "def456789012000",
              "reason" => "base_moved"
            }
          }
        )

        described_class.call(workflow: workflow)

        expect(a.reload.state).to eq("approved")
        expect(train.reload.failure_reason).to match(/merge_train: base moved/)
        expect(train.reload.failure_reason).to match(/rebuild required/)
      end

      it "defer_lands members when stale-base artifact records missing_built_base_sha" do
        a = member_job(issue_number: 1)
        train, workflow = train_with_workflow(
          [ a ],
          reason: nil,
          artifacts: {
            "merge_train_stale_base" => {
              "base_branch" => "main",
              "built_base_sha" => nil,
              "current_base_sha" => "abc123",
              "reason" => "missing_built_base_sha"
            }
          }
        )

        described_class.call(workflow: workflow)

        expect(a.reload.state).to eq("approved")
        expect(train.reload.failure_reason).to match(/merge_train: missing built base SHA/)
      end
    end

    context "when workflow.failure_reason and stale-base artifact are blank — diagnostic fallback" do
      it "defer_lands members when the failed run diagnostic carries the stale-base error message" do
        a = member_job(issue_number: 1)
        train, workflow = train_with_workflow_and_failed_run(
          [ a ],
          error_message: "merge_train: base moved from oldbase123456 to newbase654321; rebuild required"
        )

        described_class.call(workflow: workflow)

        expect(a.reload.state).to eq("approved")
        expect(train.reload.failure_reason).to match(/merge_train: base moved/)
      end

      it "fail_lands members when the failed run diagnostic carries a genuine failure message" do
        a = member_job(issue_number: 1)
        train, workflow = train_with_workflow_and_failed_run(
          [ a ],
          error_message: "grader returned non-zero exit"
        )

        described_class.call(workflow: workflow)

        expect(a.reload.state).to eq("implemented")
      end
    end

    # Regression: a failing merge_train workflow used to drive its tip
    # Job (the workflow's job) to :failed via the generic
    # propagate_fail_to_job!, so the tip needed a wasteful full Retry
    # while the other members only needed re-approval. merge_train is now
    # a landing workflow, so the fail handler is the sole authority and
    # every member — tip included — lands on :implemented.
    it "leaves the tip member :implemented (not :failed) when the whole workflow fails" do
      a = member_job(issue_number: 1)
      tip = member_job(issue_number: 2)
      train = build_train([ a, tip ])
      workflow = Workflow.create!(job: tip, trigger_kind: "merge_train",
                                  artifacts: { "merge_train_id" => train.id })
      Step.create!(workflow: workflow, kind: "merge_train_build", position: 0)
      workflow.start!
      workflow.save!
      workflow.failure_reason = "merge_train: textual conflict integrating member"

      workflow.fail!
      workflow.save!

      expect(tip.reload.state).to eq("implemented")
      expect(a.reload.state).to eq("implemented")
      expect(train.reload.state).to eq("failed")
    end
  end
end
