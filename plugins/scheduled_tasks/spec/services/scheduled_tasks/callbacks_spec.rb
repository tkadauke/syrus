require "rails_helper"

RSpec.describe ScheduledTasks::Callbacks do
  describe ".on_tick" do
    it "enqueues the scheduled task poll" do
      expect { described_class.on_tick }.to have_enqueued_job(PollScheduledTasksJob)
    end
  end
end
