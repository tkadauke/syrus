require "rails_helper"

RSpec.describe App::JobDetailPayload do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:capabilities) { { "os" => [ "macos" ], "arch" => [ "arm64" ] } }

  def placement_job
    Factories.job_record(user: user, repository: repository).tap do |job|
      job.update!(
        placement_recommendation_status: "pending",
        placement_recommendation: {
          "profile" => "macos_desktop",
          "label" => "macOS desktop",
          "capabilities" => capabilities,
          "explanation" => "The desktop package must be tested on macOS.",
          "provenance" => "ingestion_classifier"
        }
      )
    end
  end

  def recommendation_for(job)
    described_class.build(job: job, user: user).fetch(:job).fetch(:placement_recommendation)
  end

  it "reports a compatible live worker for the recommended capabilities" do
    ensure_solid_queue_test_tables!
    InstanceVersion.create!(
      hostname: "mac-worker",
      role: "worker",
      version: "abc123",
      started_at: 1.minute.ago,
      last_heartbeat_at: Time.current,
      capabilities: capabilities
    )
    SolidQueue::Process.create!(
      hostname: "mac-worker",
      kind: "Worker",
      name: "worker-1",
      pid: 123,
      last_heartbeat_at: Time.current,
      metadata: {
        "queues" => "runs-macos-arm64",
        "polling_interval" => 0.1,
        "pool_size" => 1
      }
    )

    expect(recommendation_for(placement_job)).to include("compatible_worker_available" => true)
  end

  it "reports when no compatible live worker is available" do
    ensure_solid_queue_test_tables!

    expect(recommendation_for(placement_job)).to include("compatible_worker_available" => false)
  end
end
