require "rails_helper"
RSpec.describe LocalBackups::Callbacks do
  around do |example|
    previous = ENV["SYRUS_BACKUP_SCHEDULE_ENABLED"]
    example.run
  ensure
    previous.nil? ? ENV.delete("SYRUS_BACKUP_SCHEDULE_ENABLED") : ENV["SYRUS_BACKUP_SCHEDULE_ENABLED"] = previous
  end
  it "queues maintenance and scheduled creation on consumed queues" do
    ENV["SYRUS_BACKUP_SCHEDULE_ENABLED"] = "1"
    expect { described_class.on_tick }.to have_enqueued_job(LocalBackups::MaintenanceJob).on_queue("cleanup")
      .and have_enqueued_job(LocalBackups::CreateJob).with(reason: "scheduled").on_queue("low_priority_maintenance")
  end
  it "omits creation when the schedule is disabled" do
    ENV["SYRUS_BACKUP_SCHEDULE_ENABLED"] = "0"
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    expect { described_class.on_tick }.to have_enqueued_job(LocalBackups::MaintenanceJob)
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.map { |job| job.fetch(:job) }
    expect(jobs).not_to include(LocalBackups::CreateJob)
  end
end
