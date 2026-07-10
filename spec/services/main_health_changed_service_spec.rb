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
          kind: "direct"
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

      it "does not emit a notification" do
        expect {
          described_class.on_health_change!(repository)
        }.not_to change { Notification.count }
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
    it "accepts a repository without raising" do
      expect { described_class.recovered!(repository) }.not_to raise_error
    end
  end
end
