require "rails_helper"

RSpec.describe MainHealthChangedService do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:for).and_return(github_client)
    allow(github_client).to receive(:branch_head_sha) { repository.reload.last_health_checked_sha }
  end

  describe ".on_health_change!" do
    it "logs a warning with the repository slug and health states" do
      repository.update!(ci_health: "broken")

      # allow other warn calls (e.g. from StepDispatcher for the fix job's workflow)
      allow(Rails.logger).to receive(:warn)
      expect(Rails.logger).to receive(:warn).with(
        include("MainHealthChangedService", repository.slug, "main_health=broken", "ci_health=broken")
      ).at_least(:once)

      described_class.on_health_change!(repository)
    end

    it "spawns no repair job when health is unknown" do
      expect {
        described_class.on_health_change!(repository)
      }.not_to change { repository.jobs.count }
    end

    it "ignores health changes when main branch health checking is disabled" do
      repository.update!(main_branch_health_enabled: false, ci_health: "broken")
      allow(Rails.logger).to receive(:info)

      expect {
        described_class.on_health_change!(repository)
      }.not_to change { repository.reload.landing_paused }

      expect(repository.jobs.where(kind: "direct")).to be_empty
    end

    context "when main_health transitions to broken" do
      before { settle_main_health!(repository) }

      it "sets repository.landing_paused to true" do
        expect {
          described_class.on_health_change!(repository)
        }.to change { repository.reload.landing_paused }.from(false).to(true)
      end

      it "is idempotent when landing_paused is already true" do
        repository.update!(landing_paused: true)
        expect {
          described_class.on_health_change!(repository)
        }.not_to raise_error
        expect(repository.reload.landing_paused).to be true
      end

      it "stamps active queued workflows with main_broken artifact" do
        job = Factories.job(repository: repository)
        workflow = job.latest_workflow
        workflow.update_columns(state: "queued")

        described_class.on_health_change!(repository)

        expect(workflow.reload.artifact("main_broken")).to be true
      end

      it "stamps active running workflows with main_broken artifact" do
        job = Factories.job(repository: repository)
        workflow = job.latest_workflow
        workflow.update_columns(state: "running")

        described_class.on_health_change!(repository)

        expect(workflow.reload.artifact("main_broken")).to be true
      end

      it "does not stamp terminal workflows" do
        job = Factories.job(repository: repository)
        workflow = job.latest_workflow
        workflow.update_columns(state: "succeeded", finished_at: Time.current)

        described_class.on_health_change!(repository)

        expect(workflow.reload.artifact("main_broken")).to be_nil
      end

      it "does not stamp workflows belonging to other repositories" do
        other_repo = Factories.repository(user: user)
        job = Factories.job(repository: other_repo)
        workflow = job.latest_workflow
        workflow.update_columns(state: "running")

        described_class.on_health_change!(repository)

        expect(workflow.reload.artifact("main_broken")).to be_nil
      end

      it "spawns a high-priority direct Job to fix the broken main" do
        expect {
          described_class.on_health_change!(repository)
        }.to change { repository.jobs.where(kind: "direct").count }.by(1)

        fix_job = repository.jobs.where(kind: "direct").last
        expect(fix_job).to have_attributes(
          issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          priority: "high",
          kind: "direct",
          state: "queued"
        )
        expect(fix_job.issue_body).to include(
          "Current health:",
          "- CI: broken",
          "- Graders: healthy",
          "Diagnostic logs are attached to this Job"
        )
      end

      it "does not spawn a fix Job when the broken health target is stale" do
        allow(github_client).to receive(:branch_head_sha).and_return("newer-default-branch-sha")

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }

        expect(PollMainBranchHealthJob).to have_been_enqueued.with(repository.id)
      end

      it "waits for both CI and grader signal before spawning a fix Job" do
        repository.update!(
          last_health_checked_sha: "wait123def456",
          last_ci_evaluated_sha: "wait123def456",
          ci_health: "broken",
          grader_health: "unknown"
        )
        MainBranchHealthCheck.record_ci_poll(
          repository: repository,
          sha: "wait123def456",
          ci_health: "broken",
          ci_failed_checks: [
            { name: "RSpec", url: "https://github.com/tkadauke/syrus/actions/runs/42" }
          ]
        )

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }

        status = MainHealthChangedService.new(repository.reload).repair_status
        expect(status).to include(blocked_reason: "waiting_for_health_signals", can_request: true, can_spawn: false)
      end

      it "allows a manual fix Job while waiting for settled health signals" do
        repository.update!(
          last_health_checked_sha: "wait123def456",
          last_ci_evaluated_sha: "wait123def456",
          ci_health: "broken",
          grader_health: "unknown"
        )
        MainBranchHealthCheck.record_ci_poll(
          repository: repository,
          sha: "wait123def456",
          ci_health: "broken",
          ci_failed_checks: [
            { name: "RSpec", url: "https://github.com/tkadauke/syrus/actions/runs/42" }
          ]
        )

        expect {
          described_class.ensure_repair_job!(repository, force: true)
        }.to change { repository.jobs.where(kind: "direct").count }.by(1)

        fix_job = repository.jobs.where(kind: "direct").last
        expect(fix_job).to have_attributes(
          issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          state: "queued"
        )
      end

      it "attaches captured CI failure details to the fix Job" do
        settle_main_health!(
          repository,
          sha: "abc123def456",
          ci_health: "broken",
          grader_health: "healthy",
          ci_failed_checks: [
            {
              name: "RSpec",
              conclusion: "failure",
              summary: "RSpec failed",
              log: "expected status 200",
              url: "https://github.com/tkadauke/syrus/actions/runs/42"
            }
          ]
        )

        described_class.on_health_change!(repository)

        fix_job = repository.jobs.where(kind: "direct").last
        expect(fix_job.issue_body).to include(
          "Main branch health is broken for #{repository.slug}.",
          "Default branch: #{repository.default_branch}",
          "Commit: abc123def456"
        )
        expect(fix_job.issue_body).not_to include("expected status 200")

        summary = fix_job.job_attachments.find { |attachment| attachment.filename == "main-health-abc123def456-summary.md" }
        ci_logs = fix_job.job_attachments.find { |attachment| attachment.filename == "main-health-abc123def456-ci.md" }
        expect(summary.file.download).to include("CI failed: RSpec")
        expect(ci_logs.file.download).to include(
          "RSpec",
          "RSpec failed",
          "expected status 200",
          "https://github.com/tkadauke/syrus/actions/runs/42"
        )
      end

      it "attaches captured grader failure details to the fix Job" do
        grader_job = Job.create!(
          user: user,
          repository: repository,
          kind: "main_grader",
          issue_title: "main_grader:def456abc123",
          issue_number: nil
        )
        grader_workflow = Workflows::MainGrader.instantiate(
          job: grader_job,
          artifacts: { "main_sha" => "def456abc123" }
        )
        grader_workflow.set_artifact!("iterations", [
          [
            {
              "name" => "rspec",
              "status" => "failed",
              "required" => true,
              "exit_code" => 1,
              "output" => "expected docker script to pass"
            }
          ]
        ])
        settle_main_health!(
          repository,
          workflow: grader_workflow,
          sha: "def456abc123",
          ci_health: "not_configured",
          grader_health: "broken",
          grader_failed_names: [ "coverage", "rspec" ]
        )

        described_class.on_health_change!(repository)

        fix_job = repository.jobs.where(kind: "direct").last
        expect(fix_job.issue_body).to include(
          "Commit: def456abc123",
          "tmp/attachments/main-health-def456abc123-graders.md"
        )
        expect(fix_job.issue_body).not_to include("expected docker script to pass")

        grader_logs = fix_job.job_attachments.find { |attachment| attachment.filename == "main-health-def456abc123-graders.md" }
        expect(grader_logs.file.download).to include(
          grader_workflow.slug,
          "coverage, rspec",
          "The main-branch health graders captured these results:",
          "expected docker script to pass"
        )
      end

      it "does not spawn a fix Job when auto-repair is disabled" do
        repository.update!(main_branch_repair_enabled: false)

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }

        expect(repository.reload.landing_paused).to be true
      end

      it "does not spawn a second fix Job when a legacy title-matched fix Job is already open" do
        repository.jobs.create!(
          user: user,
          kind: "direct",
          issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high"
        )

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }
      end

      it "does not spawn a second fix Job when an active repair Job already exists" do
        repository.jobs.create!(
          user: user,
          kind: "direct",
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          issue_title: "repair in flight",
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "running"
        )

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }
      end

      it "does not spawn a second fix Job when a repair Job is waiting for review" do
        repository.jobs.create!(
          user: user,
          kind: "direct",
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          issue_title: "repair awaiting review",
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "implemented"
        )

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }
      end

      it "spawns another fix Job while failed repair Jobs are below the cap" do
        repository.jobs.create!(
          user: user,
          kind: "direct",
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          issue_title: "failed repair",
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "failed"
        )

        expect {
          described_class.on_health_change!(repository)
        }.to change { repository.jobs.where(kind: "direct").count }.by(1)
      end

      it "does not spawn another fix Job once failed repair Jobs hit the cap" do
        MainHealthChangedService::MAX_OPEN_FAILED_FIX_JOBS.times do |index|
          repository.jobs.create!(
            user: user,
            kind: "direct",
            system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
            issue_title: "failed repair #{index}",
            issue_body: "fixing main",
            agent_provider: "claude",
            priority: "high",
            state: "failed"
          )
        end

        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.jobs.where(kind: "direct").count }

        status = MainHealthChangedService.new(repository).repair_status
        expect(status).to include(
          failed_open_jobs_count: MainHealthChangedService::MAX_OPEN_FAILED_FIX_JOBS,
          blocked_reason: "failed_open_cap",
          can_request: false
        )
        expect(status[:failed_jobs].map(&:issue_title)).to contain_exactly("failed repair 0", "failed repair 1", "failed repair 2")
      end

      it "spawns a new fix Job when the previous one is closed" do
        closed_job = repository.jobs.create!(
          user: user,
          kind: "direct",
          issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "closed"
        )

        expect {
          described_class.on_health_change!(repository)
        }.to change { repository.jobs.where(kind: "direct").count }.by(1)
      end

      it "spawns a replacement fix Job when a repair Job is closed while main is still broken" do
        failed_repair = repository.jobs.create!(
          user: user,
          kind: "direct",
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          issue_title: "failed repair",
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "failed"
        )

        expect {
          failed_repair.update!(state: "closed")
        }.to change { repository.jobs.where(kind: "direct").count }.by(1)

        replacement = repository.jobs.where(system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR).order(:id).last
        expect(replacement).to have_attributes(
          issue_title: MainHealthChangedService::FIX_MAIN_TITLE,
          state: "queued",
          priority: "high"
        )
      end

      it "marks main healthy instead of spawning a replacement when a repair Job lands" do
        repair = repository.jobs.create!(
          user: user,
          kind: "direct",
          system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
          issue_title: "landed repair",
          issue_body: "fixing main",
          agent_provider: "claude",
          priority: "high",
          state: "landing"
        )

        allow(MainHealthChangedService).to receive(:repair_landed!)
        allow(MainHealthChangedService).to receive(:ensure_repair_job!)

        repair.close_with_reason!("pr_merged")

        expect(MainHealthChangedService).to have_received(:repair_landed!).with(repository, job: repair)
        expect(MainHealthChangedService).not_to have_received(:ensure_repair_job!)
      end

      it "does not spawn a replacement when an unrelated Job is closed" do
        unrelated = Factories.job_record(repository: repository, user: user, state: "failed")

        expect {
          unrelated.update!(state: "closed")
        }.not_to change { repository.jobs.where(kind: "direct").count }
      end

      it "emits a main_broken notification to the repository owner" do
        repository.update!(last_health_checked_sha: "abc123def456")

        expect {
          described_class.on_health_change!(repository)
        }.to change { Notification.count }.by(1)

        notification = Notification.last
        expect(notification).to have_attributes(
          user: user,
          kind: "main_broken"
        )
        expect(notification.body).to include(repository.slug, "CI", "abc123de")
      end

      it "includes failing grader signal in notification when grader_health is broken" do
        repository.update!(grader_health: "broken", ci_health: "broken")

        described_class.on_health_change!(repository)

        expect(Notification.last.body).to include("CI", "graders")
      end

      it "only includes CI in notification when only ci_health is broken" do
        repository.update!(ci_health: "broken", grader_health: "unknown")

        described_class.on_health_change!(repository)

        expect(Notification.last.body).to include("CI")
        expect(Notification.last.body).not_to include("graders")
      end

      it "does not emit a notification if repository has no owner user" do
        repository.update_columns(user_id: nil)

        expect {
          described_class.on_health_change!(repository.reload)
        }.not_to change { Notification.count }
      end
    end

    context "when main_health is healthy" do
      before { repository.update!(ci_health: "healthy", grader_health: "healthy") }

      it "does not pause landing" do
        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.reload.landing_paused }
      end

      it "does not spawn a fix Job" do
        expect {
          described_class.on_health_change!(repository)
        }.not_to change { Job.count }
      end

      it "emits a main_recovered notification instead of main_broken when landing was paused" do
        repository.update!(landing_paused: true)
        described_class.on_health_change!(repository)
        expect(Notification.last&.kind).to eq("main_recovered")
      end

      it "does not emit a recovered notification when landing was not paused" do
        described_class.on_health_change!(repository)
        expect(Notification.last).to be_nil
      end

      it "delegates to recovered! when landing is paused" do
        repository.update!(landing_paused: true)
        expect(described_class).to receive(:recovered!).with(repository)
        described_class.on_health_change!(repository)
      end

      it "does not delegate to recovered! when landing is not paused" do
        expect(described_class).not_to receive(:recovered!)
        described_class.on_health_change!(repository)
      end
    end

    context "when main_health is unknown" do
      it "does not pause landing" do
        expect {
          described_class.on_health_change!(repository)
        }.not_to change { repository.reload.landing_paused }
      end

      it "does not spawn a fix Job" do
        expect {
          described_class.on_health_change!(repository)
        }.not_to change { Job.count }
      end

      it "does not delegate to recovered!" do
        expect(described_class).not_to receive(:recovered!)
        described_class.on_health_change!(repository)
      end

      it "does not resume repository landing when graders are healthy but CI is unknown" do
        repository.update!(landing_paused: true, ci_health: "unknown", grader_health: "healthy")

        expect(described_class).not_to receive(:recovered!)
        described_class.on_health_change!(repository)
      end

      it "resumes repository landing once graders are healthy and CI is explicitly not configured" do
        repository.update!(landing_paused: true, ci_health: "not_configured", grader_health: "healthy")

        expect(described_class).to receive(:recovered!).with(repository)
        described_class.on_health_change!(repository)
      end
    end

    context "when main_health is inconclusive" do
      before { repository.update!(ci_health: "not_configured", grader_health: "inconclusive") }

      it "pauses landing without spawning an auto-fix Job" do
        expect {
          described_class.on_health_change!(repository)
        }.to change { repository.reload.landing_paused }.from(false).to(true)

        expect(repository.jobs.where(kind: "direct")).to be_empty
      end

      it "emits a main_inconclusive notification" do
        repository.update!(last_health_checked_sha: "abc123def456")

        expect {
          described_class.on_health_change!(repository)
        }.to change { Notification.count }.by(1)

        notification = Notification.last
        expect(notification).to have_attributes(user: user, kind: "main_inconclusive")
        expect(notification.body).to include(repository.slug, "abc123de", "inconclusive")
      end

      it "does not stamp active workflows as main_broken" do
        job = Factories.job(repository: repository)
        workflow = job.latest_workflow
        workflow.update_columns(state: "running")

        described_class.on_health_change!(repository)

        expect(workflow.reload.artifact("main_broken")).to be_nil
      end
    end
  end

  describe ".recovered!" do
    before { repository.update!(ci_health: "healthy", grader_health: "healthy") }

    it "clears landing_paused on the repository" do
      repository.update!(landing_paused: true)
      described_class.recovered!(repository)
      expect(repository.reload.landing_paused).to be false
    end

    it "is idempotent when landing_paused is already false" do
      repository.update!(landing_paused: false)
      expect { described_class.recovered!(repository) }.not_to raise_error
      expect(repository.reload.landing_paused).to be false
    end

    context "unblocking queued workflows" do
      it "calls start_workflow for queued workflows with no runs" do
        job = Factories.job_record(repository: repository, state: "queued")
        blocked_workflow = Workflow.create!(
          job: job,
          user: user,
          trigger_kind: "initial",
          agent_provider: "claude"
        )
        blocked_workflow.steps.create!(kind: "prepare", position: 0, iteration: 1)

        allow(StepDispatcher).to receive(:start_workflow)
        described_class.recovered!(repository)
        expect(StepDispatcher).to have_received(:start_workflow).with(blocked_workflow)
      end

      it "does not call start_workflow for queued workflows that already have runs" do
        Factories.job(repository: repository)
        # The job's workflow has a run on its first step — it was never blocked.

        allow(StepDispatcher).to receive(:start_workflow)
        described_class.recovered!(repository)
        expect(StepDispatcher).not_to have_received(:start_workflow)
      end

      it "does not call start_workflow for queued workflows on other repositories" do
        other_repo = Factories.repository(user: user)
        other_job = Factories.job_record(repository: other_repo, state: "queued")
        other_blocked = Workflow.create!(
          job: other_job,
          user: user,
          trigger_kind: "initial",
          agent_provider: "claude"
        )
        other_blocked.steps.create!(kind: "prepare", position: 0, iteration: 1)

        allow(StepDispatcher).to receive(:start_workflow)
        described_class.recovered!(repository)
        expect(StepDispatcher).not_to have_received(:start_workflow)
      end
    end

    context "retrying held jobs" do
      let(:held_job) { Factories.job(repository: repository) }
      let(:held_workflow) { held_job.latest_workflow }

      before do
        held_workflow.update_columns(state: "failed")
        held_workflow.set_artifact!("main_broken", true)
      end

      it "enqueues a retry for failed workflows with main_broken artifact" do
        allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
          RetryWorkflowEnqueuer::Result.new(workflow: held_workflow, error: nil, circuit: nil)
        )
        described_class.recovered!(repository)
        expect(RetryWorkflowEnqueuer).to have_received(:call).with(
          job: held_job,
          provider_validation: :none,
          automatic: true
        )
      end

      it "skips failed workflows without main_broken artifact" do
        held_workflow.update!(artifacts: {})

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "skips failed workflows whose job is closed" do
        held_job.update_columns(state: "closed")

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "skips stale failed workflows after a newer workflow has succeeded" do
        Workflow.create!(
          job: held_job,
          user: user,
          trigger_kind: "retry",
          agent_provider: "claude",
          state: "succeeded"
        )

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "skips stale failed workflows while a newer workflow is active" do
        Workflow.create!(
          job: held_job,
          user: user,
          trigger_kind: "retry",
          agent_provider: "claude",
          state: "running"
        )

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "skips stale failed workflows after any newer workflow exists" do
        Workflow.create!(
          job: held_job,
          user: user,
          trigger_kind: "retry",
          agent_provider: "claude",
          state: "failed"
        )

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "skips failed workflows whose job has already been implemented" do
        held_job.update_columns(state: "implemented")

        expect(RetryWorkflowEnqueuer).not_to receive(:call)
        described_class.recovered!(repository)
      end

      it "attempts only the newest recoverable failed workflow per job" do
        newer_failed = Workflow.create!(
          job: held_job,
          user: user,
          trigger_kind: "retry",
          agent_provider: "claude",
          state: "failed"
        )
        newer_failed.set_artifact!("main_broken", true)

        allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
          RetryWorkflowEnqueuer::Result.new(workflow: newer_failed, error: nil, circuit: nil)
        )
        described_class.recovered!(repository)

        expect(RetryWorkflowEnqueuer).to have_received(:call).once.with(
          job: held_job,
          provider_validation: :none,
          automatic: true
        )
      end

      it "does not retry workflows for other repositories" do
        other_repo = Factories.repository(user: user)
        other_job = Factories.job(repository: other_repo)
        other_wf = other_job.latest_workflow
        other_wf.update_columns(state: "failed")
        other_wf.set_artifact!("main_broken", true)

        allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
          RetryWorkflowEnqueuer::Result.new(workflow: held_workflow, error: nil, circuit: nil)
        )
        described_class.recovered!(repository)

        # held_job (in repository) should be retried; other_job (in other_repo) should not
        expect(RetryWorkflowEnqueuer).to have_received(:call).with(job: held_job, provider_validation: :none, automatic: true)
        expect(RetryWorkflowEnqueuer).not_to have_received(:call).with(job: other_job, provider_validation: :none, automatic: true)
      end

      it "caps retries at MAX_RECOVERY_RETRIES" do
        (MainHealthChangedService::MAX_RECOVERY_RETRIES + 1).times do
          j = Factories.job(repository: repository)
          wf = j.latest_workflow
          wf.update_columns(state: "failed")
          wf.set_artifact!("main_broken", true)
        end
        # held_workflow + 11 more = 12 total; cap at 10

        allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
          RetryWorkflowEnqueuer::Result.new(workflow: held_workflow, error: nil, circuit: nil)
        )
        described_class.recovered!(repository)
        expect(RetryWorkflowEnqueuer).to have_received(:call).exactly(MainHealthChangedService::MAX_RECOVERY_RETRIES).times
      end
    end

    context "recovery notification" do
      it "emits a main_recovered notification" do
        expect {
          described_class.recovered!(repository)
        }.to change { Notification.count }.by(1)

        notification = Notification.last
        expect(notification).to have_attributes(user: user, kind: "main_recovered")
        expect(notification.body).to include(repository.slug)
      end

      it "includes the retry count in the notification body when jobs were retried" do
        job = Factories.job(repository: repository)
        wf = job.latest_workflow
        wf.update_columns(state: "failed")
        wf.set_artifact!("main_broken", true)

        allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
          RetryWorkflowEnqueuer::Result.new(workflow: wf, error: nil, circuit: nil)
        )
        described_class.recovered!(repository)
        expect(Notification.last.body).to include("1 job")
      end

      it "omits the retry count from the notification body when no jobs were retried" do
        described_class.recovered!(repository)
        expect(Notification.last.body).not_to include("auto-retry")
      end

      it "does not emit a notification when the repository has no owner user" do
        repository.update_columns(user_id: nil)
        expect {
          described_class.recovered!(repository.reload)
        }.not_to change { Notification.count }
      end
    end
  end

  describe ".repair_landed!" do
    it "records the merged repair commit as healthy and resumes held work" do
      settle_main_health!(repository, sha: "broken123", ci_health: "broken", grader_health: "broken")
      repository.update!(landing_paused: true)
      allow(github_client).to receive(:branch_head_sha).and_return("fixed456")
      repair = repository.jobs.create!(
        user: user,
        kind: "direct",
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: "landed repair",
        issue_body: "fixing main",
        agent_provider: "claude",
        priority: "high",
        state: "closed",
        closure_reason: "pr_merged"
      )
      workflow = Workflow.create!(
        job: repair,
        user: user,
        trigger_kind: "auto_merge",
        agent_provider: "claude",
        state: "succeeded"
      )

      described_class.repair_landed!(repository, job: repair)

      expect(repository.reload).to have_attributes(
        landing_paused: false,
        last_health_checked_sha: "fixed456",
        last_ci_evaluated_sha: "fixed456",
        last_graded_sha: "fixed456",
        ci_health: "healthy",
        grader_health: "healthy"
      )
      merged = MainBranchHealthCheck.where(repository: repository, sha: "fixed456", ci_health: "healthy", grader_health: "healthy")
      expect(merged).to exist
      expect(merged.count).to eq(1)
      expect(merged.first.workflow).to eq(workflow)
      expect(Notification.last).to have_attributes(user: user, kind: "main_recovered")
    end

    it "keeps repositories without CI configured as no-CI healthy" do
      settle_main_health!(repository, sha: "broken123", ci_health: "not_configured", grader_health: "broken")
      allow(github_client).to receive(:branch_head_sha).and_return("fixed456")
      repair = repository.jobs.create!(
        user: user,
        kind: "direct",
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: "landed repair",
        issue_body: "fixing main",
        agent_provider: "claude",
        priority: "high",
        state: "closed",
        closure_reason: "pr_merged"
      )

      described_class.repair_landed!(repository, job: repair)

      expect(repository.reload).to have_attributes(
        ci_health: "not_configured",
        grader_health: "healthy"
      )
      expect(repository.main_health).to eq("healthy")
    end
  end

  def settle_main_health!(
    repository,
    sha: "abc123def456",
    ci_health: "broken",
    grader_health: "healthy",
    ci_failed_checks: [],
    grader_failed_names: nil,
    workflow: nil
  )
    repository.update!(
      last_health_checked_sha: sha,
      last_ci_evaluated_sha: sha,
      ci_health: ci_health,
      grader_health: grader_health
    )
    MainBranchHealthCheck.record_ci_poll(
      repository: repository,
      sha: sha,
      ci_health: ci_health,
      ci_failed_checks: ci_failed_checks
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: repository,
      workflow: workflow,
      sha: sha,
      grader_health: grader_health,
      grader_failed_names: grader_failed_names
    )
    repository.reload
  end
end
