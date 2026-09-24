require "rails_helper"

RSpec.describe App::JobWorkflowsSnapshotCache do
  around do |example|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    original_registry = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    AppEvents.declare_metrics!
    described_class.declare_metrics!
    example.run
  ensure
    Rails.cache = original_cache
    Syrus::Metrics.instance_variable_set(:@registry, original_registry)
    RequestCoalescer.reset!
  end

  let(:job) { Factories.job_with_run }
  let(:workflow) { job.workflows.first }

  def outcomes
    Syrus::Metrics.counter(:syrus_detail_snapshot_requests_total).samples
      .to_h { |labels, value| [ labels[:outcome], value ] }
  end

  def fetch(admin: false, page: 1, &block)
    described_class.fetch(job: job, page: page, admin: admin, &block)
  end

  it "computes and caches the block result on a miss, recording a computed outcome" do
    calls = 0

    result = fetch { calls += 1; [ "built" ] }

    expect(result).to eq([ "built" ])
    expect(calls).to eq(1)
    expect(outcomes["computed"]).to eq(1)
  end

  it "reuses the cached result on a hit without calling the block again, recording a cache_hit outcome" do
    fetch { [ "built" ] }

    calls = 0
    result = fetch { calls += 1; [ "rebuilt" ] }

    expect(result).to eq([ "built" ])
    expect(calls).to eq(0)
    expect(outcomes["cache_hit"]).to eq(1)
  end

  it "recomputes when a nested Step's entity_revision changes, even though the Job's own revision did not" do
    fetch { [ "built" ] }
    job_revision_before = job.reload.entity_revision

    workflow.steps.first.update!(state: "running") # bumps the Step's own entity_revision via Revisionable

    calls = 0
    result = fetch { calls += 1; [ "rebuilt" ] }

    expect(job.reload.entity_revision).to eq(job_revision_before)
    expect(result).to eq([ "rebuilt" ])
    expect(calls).to eq(1)
  end

  it "keeps admin and non-admin snapshots in separate cache entries" do
    fetch(admin: false) { [ "non-admin" ] }
    fetch(admin: true) { [ "admin" ] }

    expect(fetch(admin: false) { [ "unexpected" ] }).to eq([ "non-admin" ])
    expect(fetch(admin: true) { [ "unexpected" ] }).to eq([ "admin" ])
  end

  it "keeps different pages in separate cache entries" do
    fetch(page: 1) { [ "page-1" ] }
    fetch(page: 2) { [ "page-2" ] }

    expect(fetch(page: 1) { [ "unexpected" ] }).to eq([ "page-1" ])
    expect(fetch(page: 2) { [ "unexpected" ] }).to eq([ "page-2" ])
  end
end
