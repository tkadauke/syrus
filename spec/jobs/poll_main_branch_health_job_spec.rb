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
  end

  it "sets ci_health to broken when any check fails" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("broken")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "leaves ci_health unchanged when checks are still pending" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: true, any_failed?: false, all_passed?: false })

    repository.update!(ci_health: "healthy")
    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("healthy")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "updates last_health_checked_sha and skips ci_health update when no checks exist" do
    stub_sha(sha)
    stub_check_runs({ any?: false, pending?: false, any_failed?: false, all_passed?: false })

    described_class.perform_now(repository.id)

    expect(repository.reload.ci_health).to eq("unknown")
    expect(repository.last_health_checked_sha).to eq(sha)
  end

  it "skips the job early when SHA matches last checked and health is known" do
    repository.update!(last_health_checked_sha: sha, ci_health: "healthy", grader_health: "healthy")
    stub_sha(sha)

    expect_any_instance_of(GithubClient).not_to receive(:check_runs_summary_for)
    described_class.perform_now(repository.id)
  end

  it "re-checks even when SHA matches if health is unknown" do
    repository.update!(last_health_checked_sha: sha)
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
    repository.update!(ci_health: "broken", last_health_checked_sha: "oldsha")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: true, all_passed?: false })

    expect(MainHealthChangedService).not_to receive(:on_health_change!)
    described_class.perform_now(repository.id)
  end

  it "calls MainHealthChangedService when health transitions from broken to healthy" do
    repository.update!(ci_health: "broken", grader_health: "healthy")
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
    described_class.perform_now(repository.id)
  end

  it "enqueues MainGraderWorkflowJob when the SHA changes" do
    stub_sha(sha)
    stub_check_runs({ any?: true, pending?: false, any_failed?: false, all_passed?: true })

    expect {
      described_class.perform_now(repository.id)
    }.to have_enqueued_job(MainGraderWorkflowJob).with(repository.id, sha)
  end

  it "does not enqueue MainGraderWorkflowJob when the SHA is unchanged and health is known" do
    repository.update!(last_health_checked_sha: sha, ci_health: "healthy", grader_health: "healthy")
    stub_sha(sha)

    expect {
      described_class.perform_now(repository.id)
    }.not_to have_enqueued_job(MainGraderWorkflowJob)
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

    it "does not record a health check when checks are still pending" do
      stub_sha(sha)
      stub_check_runs({ any?: true, pending?: true, any_failed?: false, all_passed?: false, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(MainBranchHealthCheck, :count)
    end

    it "does not record a health check when no CI checks exist" do
      stub_sha(sha)
      stub_check_runs({ any?: false, pending?: false, any_failed?: false, all_passed?: false, failed_checks: [] })

      expect {
        described_class.perform_now(repository.id)
      }.not_to change(MainBranchHealthCheck, :count)
    end
  end
end
