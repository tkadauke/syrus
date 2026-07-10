require "rails_helper"

RSpec.describe MainHealthChangedService do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

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

    it "does not raise when health is unknown" do
      expect { described_class.on_health_change!(repository) }.not_to raise_error
    end

    context "when main_health transitions to broken" do
      before { repository.update!(ci_health: "broken") }

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
          priority: "high",
          kind: "direct",
          state: "queued"
        )
        expect(fix_job.issue_body).to include("ci_health", "grader_health")
      end

      it "does not spawn a second fix Job when one is already open" do
        # Create an open fix job
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

      it "emits a main_recovered notification instead of main_broken" do
        described_class.on_health_change!(repository)
        expect(Notification.last&.kind).to eq("main_recovered")
      end


      it "delegates to recovered!" do
        expect(described_class).to receive(:recovered!).with(repository)
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
end
