require "rails_helper"

RSpec.describe SyrusCoverage::HitMapTtlPruneJob do
  def workflow_with_hit_map(age:)
    workflow = Factories.job.workflows.first
    record = SyrusCoverage::HitMap.store!(workflow, { "app/a.rb" => { "1" => 1 } })
    record.update_columns(created_at: age.ago)
    workflow
  end

  it "purges hit maps older than the TTL and keeps newer ones" do
    old = workflow_with_hit_map(age: (described_class::TTL_DAYS + 1).days)
    fresh = workflow_with_hit_map(age: 1.day)

    described_class.perform_now

    expect(SyrusCoverage::HitMap.attached_for?(old)).to be(false)
    expect(SyrusCoverage::HitMap.attached_for?(fresh)).to be(true)
  end

  it "also expires a hit map attached to the Workflow itself before the plugin owned storage" do
    workflow = Factories.job.workflows.first
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x"), filename: "coverage_hit_map.json.gz")
    ActiveStorage::Attachment.create!(
      name: "coverage_hit_map", record_type: "Workflow", record_id: workflow.id, blob: blob,
      created_at: (described_class::TTL_DAYS + 1).days.ago
    )

    described_class.perform_now

    expect(SyrusCoverage::HitMap.legacy_attachment_for(workflow)).to be_nil
  end

  it "is a no-op when nothing is past the TTL" do
    fresh = workflow_with_hit_map(age: 1.hour)

    described_class.perform_now

    expect(SyrusCoverage::HitMap.attached_for?(fresh)).to be(true)
  end

  it "logs a warning and continues when a purge raises" do
    old = workflow_with_hit_map(age: (described_class::TTL_DAYS + 1).days)
    allow(SyrusCoverage::HitMap).to receive(:purge_for!).and_raise(StandardError, "S3 error")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(a_string_including("SyrusCoverage::HitMapTtlPruneJob"))
    expect(old).to be_present
  end
end
