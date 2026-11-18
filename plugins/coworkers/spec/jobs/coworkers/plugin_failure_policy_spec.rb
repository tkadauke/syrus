require "rails_helper"

RSpec.describe "Coworkers plugin job failure policy" do
  [
    Coworkers::BranchRetentionSweepJob,
    Coworkers::ProvisioningCleanupJob,
    Coworkers::WorkspaceConflictTimeoutJob
  ].each do |job_class|
    it "records an exhausted failure from #{job_class.name}" do
      failing_job_class = Class.new(job_class) do
        def perform(*)
          raise "exhausted plugin job"
        end
      end
      stub_const("Coworkers::Exhausted#{job_class.name.demodulize}", failing_job_class)
      job = failing_job_class.new
      job.exception_executions[[ StandardError ].to_s] = PluginJob::RETRY_ATTEMPTS - 1

      expect { job.perform_now }.not_to raise_error

      record = PluginRecord.find_by!(name: "coworkers")
      expect(record.plugin_job_failure_count).to eq(1)
      expect(record.plugin_job_last_error).to eq("RuntimeError: exhausted plugin job")
    end
  end
end
