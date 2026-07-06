require "rails_helper"

RSpec.describe CoverageHitMapTtlPruneJob do
  def make_workflow(created_at: Time.current, with_hit_map: false)
    job = Factories.job
    wf  = job.workflows.first
    wf.update_columns(created_at: created_at)
    if with_hit_map
      # Stub the attachment so tests don't need a real blob service.
      attachment = instance_double(ActiveStorage::Attached::One, attached?: true)
      allow(wf).to receive(:coverage_hit_map).and_return(attachment)
      allow(wf).to receive(:purge_coverage_hit_map!)
    else
      attachment = instance_double(ActiveStorage::Attached::One, attached?: false)
      allow(wf).to receive(:coverage_hit_map).and_return(attachment)
    end
    wf
  end

  def stub_find_each(workflows)
    relation = double("relation")
    allow(Workflow).to receive(:where).and_call_original
    allow(Workflow).to receive(:where).with("created_at < ?", anything).and_return(relation)
    stub = allow(relation).to receive(:find_each)
    workflows.each { |wf| stub = stub.and_yield(wf) }
  end

  it "purges hit maps on workflows past the TTL" do
    old_wf = make_workflow(created_at: (described_class::TTL_DAYS + 1).days.ago, with_hit_map: true)
    stub_find_each([ old_wf ])

    described_class.perform_now

    expect(old_wf).to have_received(:purge_coverage_hit_map!)
  end

  it "skips workflows without a hit map attachment" do
    old_wf = make_workflow(created_at: (described_class::TTL_DAYS + 1).days.ago, with_hit_map: false)
    stub_find_each([ old_wf ])
    allow(old_wf).to receive(:purge_coverage_hit_map!)

    described_class.perform_now

    expect(old_wf).not_to have_received(:purge_coverage_hit_map!)
  end

  it "is a no-op when no workflows are past the TTL" do
    stub_find_each([])

    expect_any_instance_of(Workflow).not_to receive(:purge_coverage_hit_map!)
    described_class.perform_now
  end

  it "logs a warning and continues when purge raises" do
    old_wf = make_workflow(created_at: (described_class::TTL_DAYS + 1).days.ago, with_hit_map: true)
    stub_find_each([ old_wf ])
    allow(old_wf).to receive(:purge_coverage_hit_map!).and_raise(StandardError, "S3 error")
    allow(Rails.logger).to receive(:warn)

    expect { described_class.perform_now }.not_to raise_error
    expect(Rails.logger).to have_received(:warn).with(a_string_including("CoverageHitMapTtlPruneJob"))
  end
end
