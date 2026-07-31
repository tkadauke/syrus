require "rails_helper"
require "ostruct"

RSpec.describe PollRepositoryJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus", polling_enabled: true)
  end

  def issue(number: 42, labels: [ "syrus" ], body: "", state: "open", user_login: "reporter")
    OpenStruct.new(
      number: number,
      state: state,
      pull_request: nil,
      title: "Issue #{number}",
      body: body,
      user: OpenStruct.new(login: user_login),
      labels: labels.map { |name| Struct.new(:name, keyword_init: true).new(name: name) }
    )
  end

  describe "#perform with per-issue controls" do
    before do
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)
    end

    it "creates an initial workflow whose first step is implement when the skip-prepare label is present" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(labels: [ "syrus", Workflows::SKIP_PREPARE_LABEL ]) ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      workflow = job.workflows.first
      expect(job).to be_skip_prepare
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ])
      expect(workflow.first_step.kind).to eq("implement")
    end

    it "recognizes hash-shaped skip-prepare labels" do
      github_issue = issue(labels: [])
      github_issue.labels = [
        { "name" => "syrus" },
        { name: Workflows::SKIP_PREPARE_LABEL }
      ]
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ github_issue ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      workflow = job.workflows.first
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ])
    end

    it "keeps the initial workflow starting with prepare when the skip-prepare label is absent" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(labels: [ "syrus" ]) ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      workflow = job.workflows.first
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ])
      expect(workflow.first_step.kind).to eq("prepare")
    end

    it "enqueues issue image ingestion when a new issue body embeds images" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(body: "See ![screen](https://user-images.githubusercontent.com/1/screen.png)") ])

      expect {
        described_class.perform_now(repository.id)
      }.to have_enqueued_job(IngestIssueImagesJob).with(kind_of(Integer))
    end

    it "does not enqueue issue image ingestion when the issue body has no images" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(body: "No screenshots here.") ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to have_enqueued_job(IngestIssueImagesJob)
    end

    it "closes open issue jobs when GitHub reports the source issue closed" do
      job = Factories.job(user: user, repository: repository, issue_number: 720)
      run = job.runs.first
      closed_issue = issue(number: 720, state: "closed")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do |_client, _slug, _label, state: "open"|
        state == "closed" ? [ closed_issue ] : []
      end

      described_class.perform_now(repository.id)

      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("issue_closed")
      expect(run.reload).to be_cancelled
    end

    it "leaves PR-backed jobs to the PR poller when their source issue is closed" do
      job = Factories.job(user: user, repository: repository, issue_number: 720, pr_number: 9, branch_name: "syrus/issue-720-1")
      closed_issue = issue(number: 720, state: "closed")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do |_client, _slug, _label, state: "open"|
        state == "closed" ? [ closed_issue ] : []
      end

      described_class.perform_now(repository.id)

      expect(job.reload).to be_open
      expect(job.closure_reason).to be_nil
    end

    it "enqueues a ClassifyIssueJob for new classifier-pending jobs when the agent is configured" do
      user.update!(claude_oauth_token: "oat-test")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 88, body: "Classify me, consul.") ])

      expect {
        described_class.perform_now(repository.id)
      }.to have_enqueued_job(ClassifyIssueJob).with(kind_of(Integer))

      job = Job.find_by!(repository: repository, issue_number: 88)
      expect(ClassifyIssueJob).to have_been_enqueued.with(job.id)
    end

    it "holds issues created by Syrus product owners before classifier triage" do
      Factories.user(role: "product_owner", github_handle: "pm")
      user.update!(claude_oauth_token: "oat-test")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 89, user_login: "PM") ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to have_enqueued_job(ClassifyIssueJob)

      job = Job.find_by!(repository: repository, issue_number: 89)
      expect(job).to be_needs_triage
      expect(job.workflows).to be_empty
    end

    it "ingests an Epic marker declaration as an Epic without creating a Job" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 77, body: "Epic: Attachments rollout") ])

      expect {
        described_class.perform_now(repository.id)
      }.to change(Epic, :count).by(1)
        .and change(Job, :count).by(0)

      epic = Epic.last
      expect(epic).to have_attributes(
        user: user,
        repository: repository,
        title: "Attachments rollout",
        github_issue_url: "https://github.com/acme/widgets/issues/77"
      )
    end

    it "parses Epic Depends-on references while ingesting an Epic marker declaration" do
      prerequisite = Factories.epic(
        user: user,
        repository: repository,
        title: "Universal dashboard",
        github_issue_url: "https://github.com/acme/widgets/issues/534"
      )
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 535, body: "Epic: Workflows\n\nDepends-on: #534") ])

      described_class.perform_now(repository.id)

      epic = Epic.find_by!(github_issue_url: "https://github.com/acme/widgets/issues/535")
      expect(epic.depends_on_epics).to contain_exactly(prerequisite)
    end

    it "resolves pending Epic Depends-on references when the target Epic is ingested later" do
      dependent = issue(number: 535, body: "Epic: Workflows\n\nDepends-on: #534")
      prerequisite = issue(number: 534, body: "Epic: Universal dashboard")
      poll_count = 0
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do
        poll_count += 1
        poll_count == 1 ? [ dependent ] : [ prerequisite ]
      end

      described_class.perform_now(repository.id)

      epic = Epic.find_by!(github_issue_url: "https://github.com/acme/widgets/issues/535")
      expect(epic.depends_on_epics).to be_empty
      expect(epic.pending_epic_dependency_refs).to contain_exactly(
        "owner" => "acme",
        "repo" => "widgets",
        "number" => 534,
        "github_issue_url" => "https://github.com/acme/widgets/issues/534"
      )

      described_class.perform_now(repository.id)

      prerequisite_epic = Epic.find_by!(github_issue_url: "https://github.com/acme/widgets/issues/534")
      expect(epic.reload.depends_on_epics).to contain_exactly(prerequisite_epic)
      expect(epic.pending_epic_dependency_refs).to eq([])
    end

    it "attaches a child issue to an already-ingested Epic and leaves triage for the Epic block" do
      epic = Factories.epic(
        user: user,
        repository: repository,
        github_issue_url: "https://github.com/acme/widgets/issues/41",
        state: "backlog"
      )
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Epic: #41") ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      expect(job.epic).to eq(epic)
      expect(job.state).to eq("blocked_by_epic")
      expect(job.triaging_reason).to eq("classifier_pending")
      expect(job.pending_epic_reference).to eq({})
      expect(job.runs).to be_empty
    end

    it "keeps a child issue in triaging with pending_epic_ref until the Epic is ingested" do
      child = issue(number: 42, body: "Epic: #41")
      declaration = issue(number: 41, body: "Epic: Attachments rollout")
      poll_count = 0
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do
        poll_count += 1
        poll_count == 1 ? [ child ] : [ declaration ]
      end

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      expect(job.state).to eq("triaging")
      expect(job.triaging_reason).to eq("pending_epic_ref")
      expect(job.epic).to be_nil
      expect(job.pending_epic_reference).to eq(
        "owner" => "acme",
        "repo" => "widgets",
        "number" => 41,
        "github_issue_url" => "https://github.com/acme/widgets/issues/41"
      )

      described_class.perform_now(repository.id)

      epic = Epic.find_by!(github_issue_url: "https://github.com/acme/widgets/issues/41")
      expect(job.reload.epic).to eq(epic)
      expect(job.state).to eq("blocked_by_epic")
      expect(job.triaging_reason).to eq("classifier_pending")
      expect(job.pending_epic_reference).to eq({})
      expect(job.runs).to be_empty
    end

    it "sets target_repository_id to the upstream when a fork repo's child issue references an upstream epic" do
      upstream = Factories.repository(user: user, owner: "acme", name: "core")
      fork = Factories.repository(user: user, owner: "acme", name: "core-fork", upstream_repository: upstream)
      epic = Factories.epic(
        user: user,
        repository: upstream,
        github_issue_url: "https://github.com/acme/core/issues/41"
      )
      # Child issue on the fork must use owner/repo#number to resolve to the upstream epic.
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Epic: acme/core#41") ])
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)

      described_class.perform_now(fork.id)

      job = Job.find_by!(repository: fork, issue_number: 42)
      expect(job.epic).to eq(epic)
      expect(job.target_repository_id).to eq(upstream.id)
      expect(job.effective_target_repository).to eq(upstream)
    end

    it "does not convert a pending Epic reference to an epicless Job on later polls" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Epic: #41") ])

      described_class.perform_now(repository.id)
      job = Job.find_by!(repository: repository, issue_number: 42)

      expect {
        described_class.perform_now(repository.id)
      }.not_to change { job.reload.attributes.slice("state", "triaging_reason", "epic_id", "pending_epic_reference") }
    end

    it "emits a system log entry when prepare is skipped" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(labels: [ "syrus", Workflows::SKIP_PREPARE_LABEL ]) ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      run = job.runs.first
      expect(run.job_logs.pluck(:kind, :chunk)).to include([
        "system",
        "prepare skipped via '#{Workflows::SKIP_PREPARE_LABEL}' label"
      ])
    end

    it "parses Depends-on from the ingested issue body and waits to dispatch" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 41)
      prerequisite.close_with_reason!("cancelled")
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Depends-on: #41") ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to have_enqueued_job(RunJob)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      expect(job.dependencies.first.depends_on_job).to eq(prerequisite)
      expect(job.runs).to be_empty
    end

    it "starts a dependency-waiting workflow on a later poll once the dependency succeeds" do
      prerequisite = Job.create!(user: user, repository: repository, issue_number: 41)
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Depends-on: #41") ])

      described_class.perform_now(repository.id)
      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      expect(job.runs).to be_empty

      prerequisite.close_with_reason!("pr_merged")

      expect {
        described_class.perform_now(repository.id)
      }.to have_enqueued_job(RunJob)
      expect(job.reload.runs.count).to eq(1)
    end

    it "records unresolved dependency references as pending and waits to dispatch" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Depends-on: #999") ])

      expect {
        described_class.perform_now(repository.id)
      }.not_to have_enqueued_job(RunJob)

      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!
      dependency = job.dependencies.first
      expect(job.runs).to be_empty
      expect(dependency).to be_pending
      expect(dependency.unresolved_slug).to eq("acme/widgets#999")
      expect(dependency).to have_attributes(
        depends_on_job: nil,
        unresolved_owner: "acme",
        unresolved_repo: "widgets",
        unresolved_number: 999
      )
    end

    it "starts a dangling dependency workflow on a later poll once the dependency appears and succeeds" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(number: 42, body: "Depends-on: #999") ])

      described_class.perform_now(repository.id)
      job = Job.find_by!(repository: repository, issue_number: 42)
      job.advance_after_triage!

      prerequisite = Job.create!(user: user, repository: repository, issue_number: 999)
      prerequisite.close_with_reason!("pr_merged")

      expect {
        described_class.perform_now(repository.id)
      }.to have_enqueued_job(RunJob)
      expect(job.reload.dependencies.first.depends_on_job).to eq(prerequisite)
      expect(job.runs.count).to eq(1)
    end
  end

  describe "#perform", vcr: { cassette_name: "poll_repository_job/lists_issues" } do
    # Default: pretend GitHub reports no linked PR for these issues.
    # Tests covering the preempted path (below) override this stub to
    # return a real linked PR.
    before do
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_call_original
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .with(repository.slug, repository.trigger_label, state: "closed")
        .and_return([])
    end

    it "creates a Job for each issue that passes IngestPolicy and isn't dedup'd" do
      # Pre-seed: issue 46 already has a Job, must be dedup'd.
      Job.create!(user: user, repository: repository, issue_number: 46)

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1)

      created = Job.where(repository: repository).order(:created_at).last
      expect(created.issue_number).to eq(42)
      expect(created.state).to eq("triaging")
      expect(created.runs).to be_empty
    end

    it "creates a Job whose workflow skips prepare when the issue has the prepare-skip label" do
      label = Struct.new(:name)
      issue = Struct.new(:number, :state, :pull_request, :labels).new(
        99,
        "open",
        nil,
        [
          label.new("syrus"),
          label.new(Job::PREPARE_SKIP_LABEL)
        ]
      )
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_return([ issue ])

      described_class.perform_now(repository.id)

      job = Job.find_by!(repository: repository, issue_number: 99)
      job.advance_after_triage!
      workflow = job.latest_workflow
      expect(workflow.steps.pluck(:kind)).to eq(%w[ implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ])
      expect(workflow.artifact("prepare_skipped_reason")).to eq("issue_label")
    end

    it "dedups against any prior Job (open or closed) — prevents the duplicate-PR loop" do
      # Pre-seed: issue 46 has a Job whose initial run already succeeded
      # (PR is open and the thread is alive); issue 42 has a Job that
      # was closed. Either way the poller must not re-ingest. The old
      # code dedup'd only on active Job state and opened a fresh PR
      # every poll cycle.
      job_46 = Factories.job(user: user, repository: repository, issue_number: 46)
      job_46.runs.first.tap { |r| r.start!; r.succeed!; r.save! }

      job_42 = Job.create!(user: user, repository: repository, issue_number: 42)
      job_42.close_with_reason!("manual")

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)
    end

    it "skips a non-existent or polling-disabled repository" do
      repository.update!(polling_enabled: false)
      expect {
        described_class.perform_now(repository.id)
      }.not_to change(Job, :count)
    end

    it "force: true polls even when polling_enabled is false" do
      repository.update!(polling_enabled: false)
      expect {
        described_class.perform_now(repository.id, force: true)
      }.to change(Job, :count).by_at_least(1)
    end

    it "skips archived repositories even with force: true" do
      repository.archive!
      expect {
        described_class.perform_now(repository.id, force: true)
      }.not_to change(Job, :count)
    end

    describe "preempted by external PR" do
      before do
        # Cassette returns issues #42 and #46. Pretend an external PR
        # already targets #42, but #46 is unspoken-for.
        allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue) do |_inst, _slug, issue_number|
          issue_number == 42 ? { number: 99, url: "https://github.com/acme/widgets/pull/99" } : nil
        end
      end

      it "creates a brand-new issue's Job in implemented state with the external PR captured, no Run" do
        expect {
          described_class.perform_now(repository.id)
        }.to change(Job, :count).by(2)  # one for #42 (preempted), one for #46 (normal)

        preempted = Job.find_by(repository: repository, issue_number: 42)
        expect(preempted.kind).to eq("issue")
        expect(preempted.state).to eq("implemented")
        expect(preempted.closure_reason).to be_nil
        expect(preempted.external_pr_number).to eq(99)
        expect(preempted.finished_at).to be_nil
        expect(preempted.runs).to be_empty   # no auto-Run

        normal = Job.find_by(repository: repository, issue_number: 46)
        expect(normal.state).to eq("triaging")
        expect(normal.runs).to be_empty
      end

      it "attaches the external PR to a stalled prior Job and marks it implemented" do
        # Pre-seed: #42 has a Job whose initial run failed and we never opened a PR.
        prior = Factories.job(user: user, repository: repository, issue_number: 42)
        prior.runs.first.tap { |r| r.fail!; r.save! }

        expect {
          described_class.perform_now(repository.id)
        }.to change { prior.reload.external_pr_number }.from(nil).to(99)

        expect(prior).to be_implemented
        expect(prior.closure_reason).to be_nil
        expect(prior.finished_at).to be_nil
      end

      it "attaches the external PR to a Job that already has a Syrus PR and leaves it reviewable" do
        prior = Job.create!(user: user, repository: repository, issue_number: 42, pr_number: 7, branch_name: "syrus/issue-42-1")
        # Job is open with a syrus PR; we just learned about a competing external PR.
        expect {
          described_class.perform_now(repository.id)
        }.to change { prior.reload.external_pr_number }.from(nil).to(99)

        expect(prior).to be_implemented
        expect(prior.closure_reason).to be_nil
      end

      it "cancels active Runs when an external PR makes an in-flight Job reviewable" do
        prior = Factories.job(user: user, repository: repository, issue_number: 42)
        run = prior.runs.first
        run.start!  # running

        described_class.perform_now(repository.id)
        prior.reload
        expect(prior.external_pr_number).to eq(99)
        expect(prior).to be_implemented
        expect(run.reload).to be_cancelled
      end

      it "does NOT record Syrus's own PR as external (closedByPullRequestsReferences includes ours)" do
        # Same setup as the "informational" test above, except now the
        # linked PR GitHub returns IS our own PR (#7). The detector must
        # recognize itself and skip the attachment instead of pretending
        # someone else opened the PR.
        prior = Job.create!(user: user, repository: repository, issue_number: 42, pr_number: 7, branch_name: "syrus/issue-42-1")
        # Override: GraphQL returns OUR PR as the linked one for #42.
        allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue) do |_inst, _slug, issue_number|
          issue_number == 42 ? { number: 7, url: "https://github.com/acme/widgets/pull/7" } : nil
        end

        described_class.perform_now(repository.id)
        expect(prior.reload.external_pr_number).to be_nil   # still nil — it's our own PR
      end
    end
  end

  describe "poll status tracking", vcr: { cassette_name: "poll_repository_job/lists_issues" } do
    before do
      allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil)
      allow_any_instance_of(GithubClient).to receive(:issues_with_label).and_call_original
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .with(repository.slug, repository.trigger_label, state: "closed")
        .and_return([])
    end

    it "sets last_poll_status to 'ok' and records last_poll_started_at after a successful poll" do
      freeze_time do
        described_class.perform_now(repository.id)
        repository.reload
        expect(repository.last_poll_status).to eq("ok")
        expect(repository.last_poll_started_at).to eq(Time.current)
        expect(repository.last_poll_error).to be_nil
      end
    end

    it "uses the previous poll start time for recurring incremental polls" do
      since = Time.zone.parse("2026-07-15 12:00:00 UTC")
      repository.update_columns(last_poll_started_at: since)
      calls = []
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do |_client, slug, label, **kwargs|
        calls << [ slug, label, kwargs ]
        []
      end

      described_class.perform_now(repository.id)

      expect(calls).to include([ repository.slug, repository.trigger_label, { state: "open", since: since } ])
      expect(calls).to include([ repository.slug, repository.trigger_label, { state: "closed", since: since } ])
    end

    it "does a full reconciliation poll when force is true" do
      since = Time.zone.parse("2026-07-15 12:00:00 UTC")
      repository.update_columns(last_poll_started_at: since)
      calls = []
      allow_any_instance_of(GithubClient).to receive(:issues_with_label) do |_client, slug, label, **kwargs|
        calls << [ slug, label, kwargs ]
        []
      end

      described_class.perform_now(repository.id, force: true)

      expect(calls).to include([ repository.slug, repository.trigger_label, { state: "open" } ])
      expect(calls).to include([ repository.slug, repository.trigger_label, { state: "closed" } ])
      expect(calls.any? { |_slug, _label, kwargs| kwargs.key?(:since) }).to be(false)
    end

    it "sets last_poll_status to 'failed' with the error message when GitHub raises" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_raise(RuntimeError, "401 Bad credentials")

      expect {
        described_class.perform_now(repository.id)
      }.to raise_error(RuntimeError, "401 Bad credentials")

      repository.reload
      expect(repository.last_poll_status).to eq("failed")
      expect(repository.last_poll_error).to eq("401 Bad credentials")
      expect(repository.last_poll_started_at).to be_present
    end

    it "does not update poll status when the repository is archived (no poll ran)" do
      repository.archive!
      described_class.perform_now(repository.id, force: true)
      repository.reload
      expect(repository.last_poll_status).to be_nil
    end

    it "does not update poll status when polling is disabled and force is false (no poll ran)" do
      repository.update!(polling_enabled: false)
      described_class.perform_now(repository.id)
      repository.reload
      expect(repository.last_poll_status).to be_nil
    end

    it "clears a prior failed status after a successful poll" do
      repository.update_columns(last_poll_status: "failed", last_poll_error: "old error")
      described_class.perform_now(repository.id)
      repository.reload
      expect(repository.last_poll_status).to eq("ok")
      expect(repository.last_poll_error).to be_nil
    end
  end
end
