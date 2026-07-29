require "rails_helper"

RSpec.describe PollMainBranchHealthJob do
  include ActiveJob::TestHelper
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:sha) { "abc123def456" }

  def stub_sha(sha)
    allow_any_instance_of(GithubClient).to receive(:branch_head_sha).and_return(sha)
  end

  def stub_check_runs(summary)
    allow_any_instance_of(GithubClient).to receive(:check_runs_summary_for).and_return(summary)
  end

  it "sets ci_health to healthy when all checks pass" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("healthy")
    expect(repository.last_health_checked_sha).to eq(sha)
    expect(repository.last_ci_evaluated_sha).to eq(sha)
  end

  it "sets ci_health to broken when any check fails" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false, any_cancelled?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("broken")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "sets ci_health to inconclusive when all failures are cancellations" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, any_cancelled?: true, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("inconclusive")
    expect(repository.last_health_checked_sha).to eq(sha)
    expect(repository.last_ci_evaluated_sha).to eq(sha)
  end

  it "sets ci_health to inconclusive when some checks pass and some are cancelled" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, any_cancelled?: true, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("inconclusive")
  end

  it "does not mark CI broken when only cancelled checks exist" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, any_cancelled?: true, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.main_health).not_to eq("broken")
  end

  it "marks ci_health unknown when checks are still pending on a new SHA" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: true, any_failed?: false, all_passed?: false })

    repository.update!(ci_health: "healthy")
    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("unknown")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "carries broken health forward to a new SHA while checks are pending" do
    repository.update!(
      last_health_checked_sha: "oldsha",
      ci_health: "broken",
      grader_health: "broken"
    )
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: true, any_failed?: false, all_passed?: false })

    described_class.perform_now(repository.id)

    repository.reload
    expect(repository.last_health_checked_sha).to eq(sha)
    expect(repository.ci_health).to eq("broken")
    expect(repository.grader_health).to eq("broken")
    expect(repository.main_health).to eq("broken")
  end

  it "marks ci_health not_configured when no checks exist" do
    stub_sha(sha)
    stub_check_runs({ any?: false, pending?: false, any_failed?: false, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("not_configured")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "skips the job early when SHA matches last checked, health is known, and SHA has been graded" do
    repository.update!(last_health_checked_sha: sha, last_graded_sha: sha, last_ci_evaluated_sha: sha, ci_health: "healthy", grader_health: "healthy")
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)
    described_class.perform_now(repository.id)
  end

  it "does not re-poll once CI is conclusively measured broken for the SHA" do
    # A genuinely broken SHA (measured, so last_ci_evaluated_sha == sha) should
    # not re-poll every tick — it waits for a replacement SHA. Guards against
    # row spam / redundant API calls.
    repository.update!(last_health_checked_sha: sha, last_graded_sha: sha, last_ci_evaluated_sha: sha, ci_health: "broken", grader_health: "healthy")
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)
    described_class.perform_now(repository.id)
  end

  it "re-evaluates a carried-forward broken CI signal once the new SHA's checks pass" do
    # Regression: main advanced off a broken SHA, so ci_health was carried
    # forward as "broken" and last_health_checked_sha advanced to `sha` while
    # its checks were still pending. last_ci_evaluated_sha still points at the
    # OLD sha, so a later poll must re-read the now-green checks and recover —
    # rather than early-returning because main_health isn't "unknown".
    repository.update!(
      last_health_checked_sha: sha,
      last_graded_sha: sha,
      last_ci_evaluated_sha: "oldsha",
      ci_health: "broken",
      grader_health: "healthy"
    )
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    described_class.perform_now(repository.id)

    repository.reload
    expect(repository.ci_health).to eq("healthy")
    expect(repository.last_ci_evaluated_sha).to eq(sha)
    expect(repository.main_health).to eq("healthy")
  end

  it "keeps re-polling a carried-forward broken CI signal while checks stay pending" do
    repository.update!(
      last_health_checked_sha: sha,
      last_graded_sha: sha,
      last_ci_evaluated_sha: "oldsha",
      ci_health: "broken",
      grader_health: "healthy"
    )
    stub_sha(sha)

    # The job must PROCEED to re-poll (not early-return); assert the call happens.
    expect_any_instance_of(GithubClient).to receive(:check_runs_summary_for)
      .and_return({ any?: true, pending?: true, any_failed?: false, all_passed?: false })
    described_class.perform_now(repository.id)

    repository.reload
    # Still pending → stays broken, and last_ci_evaluated_sha is NOT advanced,
    # so the next tick will re-poll again until CI is conclusive.
    expect(repository.ci_health).to eq("broken")
    expect(repository.last_ci_evaluated_sha).to eq("oldsha")
  end

  it "re-checks CI even when SHA matches if health is unknown" do
    repository.update!(last_health_checked_sha: sha, last_graded_sha: sha)
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("healthy")
  end

  it "returns early when the repository does not exist" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  it "returns early for archived repositories" do
    repository.archive!
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:branch_head_sha)
    described_class.perform_now(repository.id)
  end

  it "returns early when main branch health checking is disabled" do
    repository.update!(main_branch_health_enabled: false)

    expect_any_instance_of(GithubClient).not_to receive(:branch_head_sha)
    described_class.perform_now(repository.id)
  end

  it "returns early when the branch has no HEAD SHA" do
    allow_any_instance_of(GithubClient).to receive(:branch_head_sha).and_return(nil)
    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)

    described_class.perform_now(repository.id)
  end

  it "calls MainHealthChangedService when health transitions to broken" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false })

    expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
    described_class.perform_now(repository.id)
  end

  it "does not call MainHealthChangedService when health was already broken" do
    repository.update!(ci_health: "broken", last_health_checked_sha: sha, last_graded_sha: sha, last_ci_evaluated_sha: sha)
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)
    expect(MainHealthChangedService).not_to receive(:on_health_change!)
    described_class.perform_now(repository.id)
  end

  it "reconciles repair jobs when health is already broken" do
    repository.update!(ci_health: "broken", last_health_checked_sha: sha, last_graded_sha: sha, last_ci_evaluated_sha: sha)
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)
    expect(MainHealthChangedService).to receive(:ensure_repair_job!).with(kind_of(Repository))
    described_class.perform_now(repository.id)
  end

  it "reconciles repair jobs when CI settles after graders already broke main" do
    repository.update!(
      last_health_checked_sha: sha,
      last_graded_sha: sha,
      ci_health: "unknown",
      grader_health: "broken"
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: repository,
      sha: sha,
      grader_health: "broken",
      grader_failed_names: [ "rspec" ]
    )
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false, failed_checks: [] })

    expect(MainHealthChangedService).to receive(:ensure_repair_job!).with(kind_of(Repository))
    described_class.perform_now(repository.id)
  end

  it "calls MainHealthChangedService when health transitions from unknown to healthy" do
    repository.update!(last_health_checked_sha: sha, ci_health: "unknown", grader_health: "healthy")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
    described_class.perform_now(repository.id)
  end

  it "enqueues MainGraderWorkflowJob when the SHA has not been graded yet" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    expect {
      described_class.perform_now(repository.id)
    }.to have_enqueued_job(MainGraderWorkflowJob).with(repository.id, sha)
  end

  it "keeps broken grader_health while the main grader workflow is pending on a new SHA" do
    repository.update!(last_health_checked_sha: "oldsha", grader_health: "broken")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    described_class.perform_now(repository.id)

    expect(repository.reload.grader_health).to eq("broken")
  end

  it "resets non-broken grader_health while the main grader workflow is pending on a new SHA" do
    repository.update!(last_health_checked_sha: "oldsha", grader_health: "healthy")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    described_class.perform_now(repository.id)

    expect(repository.reload.grader_health).to eq("unknown")
  end

  it "does not enqueue MainGraderWorkflowJob when the SHA has already been graded" do
    repository.update!(last_health_checked_sha: sha, last_graded_sha: sha, last_ci_evaluated_sha: sha, ci_health: "healthy", grader_health: "healthy")
    stub_sha(sha)

    expect {
      described_class.perform_now(repository.id)
    }.not_to have_enqueued_job(MainGraderWorkflowJob)
  end

  it "enqueues MainGraderWorkflowJob when SHA is current but has not been graded yet" do
    # SHA hasn't changed for CI purposes but grading hasn't run for it yet
    repository.update!(last_health_checked_sha: sha, ci_health: "healthy", grader_health: "healthy")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true, failed_checks: [] })

    expect {
      described_class.perform_now(repository.id)
    }.to have_enqueued_job(MainGraderWorkflowJob).with(repository.id, sha)
  end

  describe "MainBranchHealthCheck recording" do
    it "records a ci_poll health check when ci_health is determined" do
      stub_sha(sha)
      stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.to change(MainBranchHealthCheck, :count).by(1)

      check = MainBranchHealthCheck.last
      expect(check.source).to eq("ci_poll")
      expect(check.sha).to eq(sha)
      expect(check.ci_health).to eq("healthy")
      expect(check.repository).to eq(repository)
    end

    it "records failed_checks from the GitHub summary" do
      failed = [{ name: "RSpec", url: "https://github.com/check/42" }]
      stub_sha(sha)
      stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false, failed_checks: failed })

      described_class.perform_now(repository.id)

      check = MainBranchHealthCheck.last
      expect(check.ci_health).to eq("broken")
      expect(check.ci_failed_checks).to eq([{ "name" => "RSpec", "url" => "https://github.com/check/42" }])
    end

    it "does not duplicate terminal CI records while the main grader is still pending" do
      failed = [{ name: "RSpec", url: "https://github.com/check/42" }]
      repository.update!(
        last_health_checked_sha: sha,
        last_ci_evaluated_sha: sha,
        last_graded_sha: "older-sha",
        ci_health: "broken",
        grader_health: "unknown"
      )
      MainBranchHealthCheck.record_ci_poll(
        repository: repository,
        sha: sha,
        ci_health: "broken",
        ci_failed_checks: failed
      )
      stub_sha(sha)
      stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false, failed_checks: failed })

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(MainBranchHealthCheck, :count)
    end

    it "does not record a health check when checks are still pending" do
      stub_sha(sha)
      stub_check_runs({ any?: true, pending?: true, any_failed?: false, all_passed?: false, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(MainBranchHealthCheck, :count)
    end

    it "records a health check when no CI checks exist" do
      stub_sha(sha)
      stub_check_runs({ any?: false, pending?: false, any_failed?: false, all_passed?: false, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.to change(MainBranchHealthCheck, :count).by(1)

      check = MainBranchHealthCheck.last
      expect(check.ci_health).to eq("not_configured")
    end

    it "does not duplicate no-CI health records for the same SHA" do
      repository.update!(last_health_checked_sha: sha, ci_health: "not_configured")
      MainBranchHealthCheck.record_ci_poll(repository: repository, sha: sha, ci_health: "not_configured")
      stub_sha(sha)
      stub_check_runs({ any?: false, pending?: false, any_failed?: false, all_passed?: false, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(MainBranchHealthCheck, :count)
    end
  end
end
