require "rails_helper"

RSpec.describe PollRepositoryJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) do
    Factories.repository(user: user, owner: "acme", name: "widgets", trigger_label: "syrus", polling_enabled: true)
  end

  def issue(number: 42, labels: [ "syrus" ])
    Struct.new(:number, :state, :labels, :pull_request, keyword_init: true).new(
      number: number,
      state: "open",
      pull_request: nil,
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
      workflow = job.workflows.first
      expect(job).to be_skip_prepare
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement summarize pr_open ])
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

      workflow = Job.find_by!(repository: repository, issue_number: 42).workflows.first
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ implement summarize pr_open ])
    end

    it "keeps the initial workflow starting with prepare when the skip-prepare label is absent" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(labels: [ "syrus" ]) ])

      described_class.perform_now(repository.id)

      workflow = Job.find_by!(repository: repository, issue_number: 42).workflows.first
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ prepare implement summarize pr_open ])
      expect(workflow.first_step.kind).to eq("prepare")
    end

    it "emits a system log entry when prepare is skipped" do
      allow_any_instance_of(GithubClient).to receive(:issues_with_label)
        .and_return([ issue(labels: [ "syrus", Workflows::SKIP_PREPARE_LABEL ]) ])

      described_class.perform_now(repository.id)

      run = Job.find_by!(repository: repository, issue_number: 42).runs.first
      expect(run.job_logs.pluck(:kind, :chunk)).to include([
        "system",
        "prepare skipped via '#{Workflows::SKIP_PREPARE_LABEL}' label"
      ])
    end
  end

  describe "#perform", vcr: { cassette_name: "poll_repository_job/lists_issues" } do
    # Default: pretend GitHub reports no linked PR for these issues.
    # Tests covering the preempted path (below) override this stub to
    # return a real linked PR.
    before { allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil) }

    it "creates a Job for each issue that passes IngestPolicy and isn't dedup'd" do
      # Pre-seed: issue 46 already has a Job, must be dedup'd.
      Job.create!(user: user, repository: repository, issue_number: 46)

      expect {
        described_class.perform_now(repository.id)
      }.to change(Job, :count).by(1)

      created = Job.where(repository: repository).order(:created_at).last
      expect(created.issue_number).to eq(42)
      expect(created.state).to eq("open")
      expect(created.runs.first.state).to eq("queued")
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

      workflow = Job.find_by!(repository: repository, issue_number: 99).latest_workflow
      expect(workflow.steps.pluck(:kind)).to eq(%w[ implement summarize pr_open ])
      expect(workflow.artifact("prepare_skipped_reason")).to eq("issue_label")
    end

    it "dedups against any prior Job (open or closed) — prevents the duplicate-PR loop" do
      # Pre-seed: issue 46 has a Job whose initial run already succeeded
      # (PR is open and the thread is alive); issue 42 has a Job that
      # was closed. Either way the poller must not re-ingest. The old
      # code dedup'd only on active Job state and opened a fresh PR
      # every poll cycle.
      job_46 = Job.create!(user: user, repository: repository, issue_number: 46)
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

      it "creates a brand-new issue's Job in closed/preempted state with the external PR captured, no Run" do
        expect {
          described_class.perform_now(repository.id)
        }.to change(Job, :count).by(2)  # one for #42 (preempted), one for #46 (normal)

        preempted = Job.find_by(repository: repository, issue_number: 42)
        expect(preempted.state).to eq("closed")
        expect(preempted.closure_reason).to eq("preempted")
        expect(preempted.external_pr_number).to eq(99)
        expect(preempted.finished_at).to be_present
        expect(preempted.runs).to be_empty   # no auto-Run

        normal = Job.find_by(repository: repository, issue_number: 46)
        expect(normal.state).to eq("open")
        expect(normal.runs.size).to eq(1)
      end

      it "attaches the external PR to a stalled prior Job (failed, no Syrus PR shipped) and closes it as preempted" do
        # Pre-seed: #42 has a Job whose initial run failed and we never opened a PR.
        prior = Job.create!(user: user, repository: repository, issue_number: 42)
        prior.runs.first.tap { |r| r.fail!; r.save! }

        expect {
          described_class.perform_now(repository.id)
        }.to change { prior.reload.external_pr_number }.from(nil).to(99)

        expect(prior).to be_closed
        expect(prior.closure_reason).to eq("preempted")
      end

      it "attaches the external PR to a Job that already has a Syrus PR (informational) — does NOT close it" do
        prior = Job.create!(user: user, repository: repository, issue_number: 42, pr_number: 7, branch_name: "syrus/issue-42-1")
        # Job is open with a syrus PR; we just learned about a competing external PR.
        expect {
          described_class.perform_now(repository.id)
        }.to change { prior.reload.external_pr_number }.from(nil).to(99)

        expect(prior).to be_open                  # NOT closed
        expect(prior.closure_reason).to be_nil
      end

      it "leaves a Job alone if it has an active Run (mid-flight), but still records the external PR" do
        prior = Job.create!(user: user, repository: repository, issue_number: 42)
        prior.runs.first.start!  # running

        described_class.perform_now(repository.id)
        prior.reload
        expect(prior.external_pr_number).to eq(99)
        expect(prior).to be_open
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
    before { allow_any_instance_of(GithubClient).to receive(:linked_open_pr_for_issue).and_return(nil) }

    it "sets last_poll_status to 'ok' and records last_poll_started_at after a successful poll" do
      freeze_time do
        described_class.perform_now(repository.id)
        repository.reload
        expect(repository.last_poll_status).to eq("ok")
        expect(repository.last_poll_started_at).to eq(Time.current)
        expect(repository.last_poll_error).to be_nil
      end
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
