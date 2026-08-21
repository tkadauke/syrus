require "rails_helper"

RSpec.describe CoverageHitMapTtlPruneJob do
  def make_workflow(created_at: Time.current, with_hit_map: false)
    job = Factories.job
    wf  = job.workflows.first
    wf.update_columns(created_at: created_at)
    if with_hit_map
      allow(wf).to receive(:purge_coverage_hit_map!)
    end
    wf
  end

  def stub_find_each(workflows)
    relation = double("relation")
    scoped_relation = double("scoped_relation")
    allow(Workflow).to receive(:joins).and_call_original
    allow(Workflow).to receive(:joins).with(:coverage_hit_map_attachment).and_return(relation)
    allow(relation).to receive(:where).with("workflows.created_at < ?", anything).and_return(scoped_relation)
    stub = allow(scoped_relation).to receive(:find_each)
    workflows.each { |wf| stub = stub.and_yield(wf) }
  end

  it "purges old workflows from the attachment-scoped relation" do
    old_wf = make_workflow(created_at: (described_class::TTL_DAYS + 1).days.ago, with_hit_map: true)
    stub_find_each([ old_wf ])

    described_class.perform_now

    expect(old_wf).to have_received(:purge_coverage_hit_map!)
  end

  it "only scans workflows that have a coverage hit map attachment" do
    relation = double("relation")
    scoped_relation = double("scoped_relation")
    allow(Workflow).to receive(:joins).with(:coverage_hit_map_attachment).and_return(relation)
    allow(relation).to receive(:where).with("workflows.created_at < ?", anything).and_return(scoped_relation)
    allow(scoped_relation).to receive(:find_each)

    described_class.perform_now

    expect(Workflow).to have_received(:joins).with(:coverage_hit_map_attachment)
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
