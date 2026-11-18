require "rails_helper"

RSpec.describe PluginJob, :reset_plugin_registry do
  before do
    Syrus::PluginRegistry.register(name: "external_reports", version: "1.0.0")
    stub_const("ExternalReportsJob", Class.new(described_class) do
      owned_by_plugin "external_reports"
      def perform = nil
    end)
  end

  it "routes plugin jobs to their plugin queue without changing core jobs" do
    expect(ExternalReportsJob.perform_later.queue_name).to eq("plugin_external_reports")
    expect(ApplicationJob.new.queue_name).to eq("control_plane")
  end

  it "infers bundled plugin ownership from the job source path" do
    expect(InsightSweepJob.plugin_owner).to eq("agent_insights")
  end

  it "preserves an explicit queue on a bundled plugin job" do
    expect(InsightSweepJob.new.queue_name).to eq("low_priority_maintenance")
  end

  it "allows a job to override the plugin queue" do
    stub_const("UrgentExternalReportsJob", Class.new(described_class) do
      owned_by_plugin "external_reports"
      queue_as :control_plane
      def perform = nil
    end)

    expect(UrgentExternalReportsJob.perform_later.queue_name).to eq("control_plane")
  end

  it "uses the manifest concurrency override for the shared plugin semaphore" do
    Syrus::PluginRegistry.register(name: "external_reports", version: "1.0.0", job_concurrency: 7)

    expect(ExternalReportsJob.concurrency_limit).to eq(7)
    expect(ExternalReportsJob.new.concurrency_key).to eq("plugin_jobs/external_reports")
  end

  it "preserves a job-specific concurrency override" do
    stub_const("SerialExternalReportsJob", Class.new(described_class) do
      owned_by_plugin "external_reports"
      limits_concurrency to: 1, key: ->(*) { "serial_reports" }
    end)

    expect(SerialExternalReportsJob.concurrency_limit).to eq(1)
  end

  it "records an exhausted failure in plugin health before discarding it" do
    stub_const("FailingExternalReportsJob", Class.new(described_class) do
      owned_by_plugin "external_reports"

      def perform
        raise "still broken"
      end
    end)
    job = FailingExternalReportsJob.new
    job.exception_executions = { "[StandardError]" => described_class::MAX_ATTEMPTS - 1 }

    expect { job.perform_now }
      .to change { Syrus::PluginInvocation.runtime_health.failures(plugin: "external_reports").size }.by(1)
    expect(PluginRecord.find_by!(name: "external_reports").last_error_at).to be_present
    expect(Syrus::PluginInvocation.runtime_health.failures(plugin: "external_reports").sole)
      .to have_attributes(extension_point: "background_job", operation: "FailingExternalReportsJob", count: 1)
  end

  it "does not record exceptions handled by a job's discard policy as exhausted failures" do
    stub_const("StaleExternalReportsJob", Class.new(described_class) do
      owned_by_plugin "external_reports"
      discard_on ActiveRecord::RecordNotFound

      def perform
        raise ActiveRecord::RecordNotFound, "report was removed"
      end
    end)

    expect { StaleExternalReportsJob.perform_now }
      .not_to change { Syrus::PluginInvocation.runtime_health.failures(plugin: "external_reports").size }
    expect(PluginRecord.find_by!(name: "external_reports").last_error_at).to be_nil
  end

  it "redacts credentials from discarded failure health and logs" do
    error = RuntimeError.new("request failed for https://x-access-token:github_pat_secret123@github.com/example/repo")
    logs = StringIO.new

    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(logs))
    ExternalReportsJob.record_discard(error)

    failure = Syrus::PluginInvocation.runtime_health
      .failures(plugin: "external_reports")
      .find { |item| item.operation == "ExternalReportsJob" }
    expect(failure.exception_class).to eq("RuntimeError")
    expect(failure.message).to include(CommandRedactor::REDACTED)
    expect(failure.message).not_to include("github_pat_secret123")
    expect(logs.string).to include(CommandRedactor::REDACTED)
    expect(logs.string).not_to include("github_pat_secret123")
  end
end
