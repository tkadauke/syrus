require "rails_helper"

RSpec.describe Workflows::MainGrader do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) do
    Job.create!(
      user: user,
      repository: repository,
      kind: "main_grader",
      issue_title: "main_grader:abc123",
      issue_number: nil
    )
  end
  let(:sha) { "abc123def456" }

  describe "chain" do
    it "materializes prepare → grader_fanout → grader_collect" do
      workflow = described_class.instantiate(job: job, artifacts: { "main_sha" => sha })

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ prepare grader_fanout grader_collect ])
      expect(workflow.trigger_kind).to eq("main_grader")
    end

    it "honors repository-level prepare disablement" do
      repository.update!(prepare_enabled: false)

      workflow = described_class.instantiate(job: job, artifacts: { "main_sha" => sha })

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(%w[ grader_fanout grader_collect ])
      expect(workflow.artifact("prepare_skipped_reason")).to eq("repository_configuration")
    end

    it "stores the main_sha in artifacts" do
      workflow = described_class.instantiate(job: job, artifacts: { "main_sha" => sha })

      expect(workflow.artifact("main_sha")).to eq(sha)
    end

    it "uses the runs queue" do
      expect(described_class.queue_name).to eq(:runs)
    end
  end

  describe ".after_success" do
    let(:workflow) { described_class.instantiate(job: job, artifacts: { "main_sha" => sha }) }

    it "updates grader_health to healthy" do
      described_class.after_success(workflow)

      expect(repository.reload.grader_health).to eq("healthy")
    end

    it "links the created health check record to the workflow" do
      described_class.after_success(workflow)

      check = MainBranchHealthCheck.last
      expect(check.workflow).to eq(workflow)
    end

    it "closes the anchor Job" do
      described_class.after_success(workflow)

      expect(job.reload.state).to eq("closed")
    end

    it "calls MainHealthChangedService when health transitions" do
      repository.update!(grader_health: "broken")

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
      described_class.after_success(workflow)
    end

    it "does not call MainHealthChangedService when health was already healthy and main stays healthy" do
      repository.update!(grader_health: "healthy", ci_health: "healthy")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_success(workflow)
    end

    it "does not call MainHealthChangedService when graders recover while CI remains unknown and landing is paused" do
      repository.update!(landing_paused: true, grader_health: "unknown", ci_health: "unknown")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_success(workflow)
    end

    it "calls MainHealthChangedService when graders recover and CI is explicitly not configured" do
      repository.update!(landing_paused: true, grader_health: "unknown", ci_health: "not_configured")

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
      described_class.after_success(workflow)
    end
  end

  describe ".after_fail" do
    let(:workflow) { described_class.instantiate(job: job, artifacts: { "main_sha" => sha }) }

    it "updates grader_health to broken" do
      create_failed_required_grader!(workflow)

      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("broken")
    end

    it "records the failing grader names in the health-check history" do
      create_failed_required_grader!(workflow, name: "rspec")

      described_class.after_fail(workflow)

      check = MainBranchHealthCheck.last
      expect(check.source).to eq("grader_workflow")
      expect(check.grader_health).to eq("broken")
      expect(check.grader_failed_names).to eq([ "rspec" ])
    end

    it "links the created health check record to the workflow" do
      create_failed_required_grader!(workflow)

      described_class.after_fail(workflow)

      check = MainBranchHealthCheck.last
      expect(check.workflow).to eq(workflow)
    end

    it "does not mark grader_health broken when setup fails before graders run" do
      repository.update!(grader_health: "healthy", ci_health: "healthy")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("healthy")
    end

    it "leaves grader_health unknown and retries when a required grader is interrupted by worker death" do
      repository.update!(grader_health: "unknown", ci_health: "healthy")
      grader_step = create_failed_required_grader!(workflow, name: "rspec")
      create_failed_run!(grader_step, agent_outcome: "worker_died")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)

      expect {
        described_class.after_fail(workflow)
      }.to have_enqueued_job(MainGraderWorkflowJob).with(repository.id, sha)

      expect(repository.reload.grader_health).to eq("unknown")
      check = MainBranchHealthCheck.last
      expect(check.grader_health).to eq("unknown")
      expect(check.grader_failed_names).to eq([ "rspec" ])
      expect(check.workflow).to eq(workflow)
    end

    it "marks timed-out required graders inconclusive instead of broken" do
      repository.update!(grader_health: "unknown", ci_health: "not_configured")
      create_failed_required_grader!(
        workflow,
        name: "coverage",
        details: {
          "exit_code" => Steps::Grader::TIMEOUT_EXIT_CODE,
          "timed_out" => true
        }
      )

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

      expect {
        described_class.after_fail(workflow)
      }.not_to have_enqueued_job(MainGraderWorkflowJob)

      expect(repository.reload.grader_health).to eq("inconclusive")
      expect(repository.main_health).to eq("inconclusive")

      check = MainBranchHealthCheck.last
      expect(check.grader_health).to eq("inconclusive")
      expect(check.grader_failed_names).to eq([ "coverage" ])
    end

    it "marks timed-out required graders broken when the repository opts in" do
      repository.update!(
        grader_health: "unknown",
        ci_health: "not_configured",
        treat_grader_timeouts_as_failures: true
      )
      create_failed_required_grader!(
        workflow,
        name: "coverage",
        details: {
          "exit_code" => Steps::Grader::TIMEOUT_EXIT_CODE,
          "timed_out" => true
        }
      )

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("broken")

      check = MainBranchHealthCheck.last
      expect(check.grader_health).to eq("broken")
      expect(check.grader_failed_names).to eq([ "coverage" ])
    end

    it "marks test-runner timeout output inconclusive instead of broken" do
      repository.update!(grader_health: "unknown", ci_health: "not_configured")
      create_failed_required_grader!(
        workflow,
        name: "react-tests",
        details: {
          "exit_code" => 1,
          "timed_out" => false,
          "output" => "Error: Test timed out in 5000ms."
        }
      )

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("inconclusive")

      check = MainBranchHealthCheck.last
      expect(check.grader_health).to eq("inconclusive")
      expect(check.grader_failed_names).to eq([ "react-tests" ])
    end

    it "does not treat an explicit 124 exit as inconclusive when timeout metadata is false" do
      repository.update!(grader_health: "unknown", ci_health: "not_configured")
      create_failed_required_grader!(
        workflow,
        name: "tests",
        details: {
          "exit_code" => Steps::Grader::TIMEOUT_EXIT_CODE,
          "timed_out" => false
        }
      )

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))

      described_class.after_fail(workflow)

      expect(repository.reload.grader_health).to eq("broken")
    end

    it "does not record another unknown result or retry when the SHA already has a conclusive grader result" do
      repository.update!(ci_health: "not_configured", grader_health: "healthy")
      MainBranchHealthCheck.record_grader_workflow(repository: repository, sha: sha, grader_health: "healthy")
      grader_step = create_failed_required_grader!(workflow, name: "coverage")
      create_failed_run!(grader_step, agent_outcome: "worker_died")

      expect(MainHealthChangedService).not_to receive(:on_health_change!)

      expect {
        expect {
          described_class.after_fail(workflow)
        }.not_to have_enqueued_job(MainGraderWorkflowJob)
      }.not_to change(MainBranchHealthCheck, :count)

      expect(repository.reload.grader_health).to eq("healthy")
      expect(job.reload.state).to eq("closed")
    end

    it "closes the anchor Job" do
      described_class.after_fail(workflow)

      expect(job.reload.state).to eq("closed")
    end

    it "calls MainHealthChangedService when health transitions to broken" do
      repository.update!(grader_health: "healthy", ci_health: "healthy")
      create_failed_required_grader!(workflow)

      expect(MainHealthChangedService).to receive(:on_health_change!).with(kind_of(Repository))
      described_class.after_fail(workflow)
    end

    it "reconciles repair jobs when graders settle after CI already broke main" do
      repository.update!(
        last_health_checked_sha: sha,
        last_ci_evaluated_sha: sha,
        ci_health: "broken",
        grader_health: "unknown"
      )
      MainBranchHealthCheck.record_ci_poll(
        repository: repository,
        sha: sha,
        ci_health: "broken",
        ci_failed_checks: [ { name: "RSpec", url: "https://github.com/check/1" } ]
      )
      create_failed_required_grader!(workflow)

      expect(MainHealthChangedService).to receive(:ensure_repair_job!).with(kind_of(Repository))
      described_class.after_fail(workflow)
    end

    it "does not call MainHealthChangedService when grader_health was already broken" do
      repository.update!(grader_health: "broken")
      create_failed_required_grader!(workflow)

      expect(MainHealthChangedService).not_to receive(:on_health_change!)
      described_class.after_fail(workflow)
    end
  end

  def create_failed_required_grader!(workflow, name: "rspec", details: {})
    workflow.steps.create!(
      kind: "grader",
      position: 1,
      state: "failed",
      details: {
        "name" => name,
        "required" => true,
        "exit_code" => 1
      }.merge(details)
    )
  end

  def create_failed_run!(step, agent_outcome:)
    step.runs.create!(
      job: job,
      user: user,
      trigger_kind: step.workflow.trigger_kind,
      agent_provider: step.workflow.agent_provider,
      state: "failed",
      agent_outcome: agent_outcome
    )
  end
end
