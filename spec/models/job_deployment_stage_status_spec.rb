require "rails_helper"

RSpec.describe JobDeploymentStageStatus do
  it "belongs to a job and enforces one row per job/stage" do
    job = Factories.job_record(landed_sha: "abc123", state: "closed")
    described_class.create!(job: job, stage_name: "staging", reached_at: Time.current, tag_sha: "tagsha")

    duplicate = described_class.new(job: job, stage_name: "staging", reached_at: Time.current)

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:stage_name]).to include("has already been taken")
  end
end
