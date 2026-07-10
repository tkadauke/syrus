require "rails_helper"

RSpec.describe MainConcernAggregator do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def create_report(repo: repository, **overrides)
    # Use job_record + bare Workflow/Run rows to avoid StepDispatcher's
    # main_health_broken? guard, which skips Run creation when main is broken.
    # Run.step is optional, so the user_matches_execution_graph validation
    # only checks user_id == job.user_id.
    user = repo.user
    job = Factories.job_record(repository: repo, user: user, state: "running")
    workflow = Workflow.create!(
      job: job, user: user, trigger_kind: "initial", agent_provider: "claude"
    )
    run = Run.create!(
      job: job, user: user, trigger_kind: "initial", agent_provider: "claude"
    )
    MainConcernReport.create!({
      repository: repo,
      job: job,
      workflow: workflow,
      run: run,
      reason: "graders failing in files I did not touch"
    }.merge(overrides))
  end

  describe ".check!" do
    context "when below threshold" do
      before { AppSetting.current.update!(main_concern_report_threshold: 2) }

      it "does not change repository health with only one report" do
        create_report
        expect {
          described_class.check!(repository)
        }.not_to change { repository.reload.grader_health }
      end

      it "does not pause landing" do
        create_report
        expect {
          described_class.check!(repository)
        }.not_to change { repository.reload.landing_paused }
      end
    end

    context "when threshold is met" do
      before { AppSetting.current.update!(main_concern_report_threshold: 2) }

      it "sets grader_health to broken" do
        2.times { create_report }
        expect {
          described_class.check!(repository)
        }.to change { repository.reload.grader_health }.to("broken")
      end

      it "triggers MainHealthChangedService.on_health_change!" do
        2.times { create_report }
        expect(MainHealthChangedService).to receive(:on_health_change!).with(repository)
        described_class.check!(repository)
      end

      it "pauses landing via MainHealthChangedService" do
        2.times { create_report }
        expect {
          described_class.check!(repository)
        }.to change { repository.reload.landing_paused }.to(true)
      end
    end

    context "when repository main_health is already broken" do
      before do
        repository.update!(ci_health: "broken")
        AppSetting.current.update!(main_concern_report_threshold: 2)
      end

      it "skips the aggregation entirely" do
        2.times { create_report }
        expect(MainHealthChangedService).not_to receive(:on_health_change!)
        described_class.check!(repository)
      end
    end

    context "with reports outside the 30-minute window" do
      before { AppSetting.current.update!(main_concern_report_threshold: 2) }

      it "does not count old reports toward the threshold" do
        create_report(created_at: 31.minutes.ago)
        create_report

        expect {
          described_class.check!(repository)
        }.not_to change { repository.reload.grader_health }
      end
    end

    context "with a configurable threshold" do
      it "fires at threshold=3 when 3 reports exist" do
        AppSetting.current.update!(main_concern_report_threshold: 3)
        3.times { create_report }
        expect {
          described_class.check!(repository)
        }.to change { repository.reload.grader_health }.to("broken")
      end

      it "does not fire at threshold=3 when only 2 reports exist" do
        AppSetting.current.update!(main_concern_report_threshold: 3)
        2.times { create_report }
        expect {
          described_class.check!(repository)
        }.not_to change { repository.reload.grader_health }
      end
    end
  end
end
