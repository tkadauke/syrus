require "rails_helper"

RSpec.describe ApplicationJob do
  before do
    stub_const("RepeatedAppSettingReadJob", Class.new(ApplicationJob) do
      def perform
        AppSetting.polling_paused?
        AppSetting.runs_paused?
        AppSetting.github_app_registered?
      end
    end)
  end

  it "reuses the application setting singleton throughout one job" do
    allow(AppSetting).to receive(:find_or_create_by!).and_call_original

    RepeatedAppSettingReadJob.perform_now

    expect(AppSetting).to have_received(:find_or_create_by!).once
  end

  it "clears the application setting cache after the job" do
    RepeatedAppSettingReadJob.perform_now
    allow(AppSetting).to receive(:find_or_create_by!).and_call_original

    AppSetting.current

    expect(AppSetting).to have_received(:find_or_create_by!).once
  end
end
