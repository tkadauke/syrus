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
    workflow = Workflow.create!(job: owner_job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id })
    step = Step.create!(workflow: workflow, kind: kind, position: 0)
    run = Run.create!(job: owner_job, step: step, trigger_kind: "merge_train")
    klass.new(run)
  end

  def stub_git(handler, head: "intsha999")
    workspace = instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new("/tmp/ws"), branch_name: "x")
    git = instance_double(GitRunner)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(git).to receive(:run)
    allow(git).to receive(:run).with("rev-parse", "HEAD", chdir: "/tmp/ws").and_return("#{head}\n")
    git
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
  end

  describe Steps::MergeTrainBuild do
    it "rebases each member onto the integration tip (mechanically) and marks the train grading" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      handler = step_handler(described_class, "merge_train_build", train, b)
      git = stub_git(handler)
      allow(handler).to receive(:run_agent)

      handler.call

      expect(git).to have_received(:run).with("checkout", "-B", train.integration_branch, "FETCH_HEAD", chdir: "/tmp/ws")
      # Mechanical rebase per member; no agent on the clean path.
      expect(git).to have_received(:run).with("rebase", train.integration_branch, chdir: "/tmp/ws").twice
      expect(git).to have_received(:run).with("merge", "--ff-only", anything, chdir: "/tmp/ws").twice
      expect(handler).not_to have_received(:run_agent)
      expect(train.reload.state).to eq("grading")
      expect(train.integration_sha).to eq("intsha999")
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
      allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: 777))
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
      allow(client).to receive(:add_issue_comment)
      allow(client).to receive(:close_pull_request)
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
  end

  describe MergeTrainFailureHandler do
    def train_with_workflow(members, reason:)
      train = build_train(members)
      workflow = Workflow.create!(job: members.last, trigger_kind: "merge_train",
                                  artifacts: { "merge_train_id" => train.id },
                                  failure_reason: reason)
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
