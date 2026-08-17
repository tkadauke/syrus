require "rails_helper"

RSpec.describe BackendExceptionLogging do
  before do
    allow(SyrusVersion).to receive(:current).and_return("backend-sha")
    allow(SyrusVersion).to receive(:hostname).and_return("host-a")
  end

  it "records request exceptions independent of operational log indexing" do
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(false)
    exception = NoMethodError.new("undefined method `map' for nil")
    exception.set_backtrace([ Rails.root.join("app/controllers/widgets_controller.rb:12").to_s ])

    described_class.ingest_request({
      exception: [ "NoMethodError", exception.message ],
      exception_object: exception,
      method: "GET",
      path: "/jobs/3188",
      controller: "JobsController",
      action: "show",
      status: 500,
      request_id: "req-abc"
    }, 123.4)

    event = BackendExceptionEvent.last
    expect(event).to have_attributes(
      app_revision: "backend-sha",
      hostname: "host-a",
      source: "action_controller",
      role: "web",
      exception_class: "NoMethodError",
      path: "/jobs/3188",
      request_id: "req-abc",
      status: 500
    )
    expect(event.metadata).to include("duration_ms" => "123.4")
  end

  it "records active job exceptions with the current run context" do
    run = Factories.run
    Thread.current[:syrus_current_run] = run
    active_job = PollInputSourceJob.new
    active_job.provider_job_id = "active-1"
    exception = ActiveRecord::ConnectionNotEstablished.new("Too many connections")

    described_class.ingest_job({
      job: active_job,
      exception: [ "ActiveRecord::ConnectionNotEstablished", exception.message ],
      exception_object: exception
    }, 456.7)

    event = BackendExceptionEvent.last
    expect(event).to have_attributes(
      source: "active_job",
      role: "worker",
      exception_class: "ActiveRecord::ConnectionNotEstablished",
      job_class: "PollInputSourceJob",
      job_id: run.job_id,
      workflow_id: run.workflow_id,
      run_id: run.id
    )
    expect(event.metadata).to include("duration_ms" => "456.7")
  ensure
    Thread.current[:syrus_current_run] = nil
  end
end
