require "rails_helper"

RSpec.describe RuntimeImageVerificationDispatchJob do
  it "moves scanner work onto the runtime image build queue" do
    expect { described_class.perform_now("db-2") }
      .to have_enqueued_job(RuntimeImageVerificationSweepJob).with("db-2").on_queue("runtime_image_builds")
  end
end
