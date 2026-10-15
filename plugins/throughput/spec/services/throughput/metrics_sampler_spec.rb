require "rails_helper"

RSpec.describe Throughput::MetricsSampler do
  include ActiveSupport::Testing::TimeHelpers

  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare_plugin("throughput") do
      counter :landing_units_total, tags: %i[unit_type]
      counter :jobs_landed_total
    end
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def auto_merge_workflow(job, state: "succeeded", finished_at: Time.current)
    Workflow.create!(
      job: job, user: job.user, trigger_kind: "auto_merge", agent_provider: job.agent_provider,
      state: state, started_at: finished_at - 1.minute, finished_at: finished_at
    )
  end

  def succeeded_merge_train(member_count:, finished_at: Time.current)
    train = MergeTrain.create!(
      repository: repository, base_branch: "main", priority: "medium", state: "succeeded", finished_at: finished_at
    )
    member_count.times do |index|
      member_job = Factories.job_record(user: user, repository: repository, issue_number: 900 + index)
      MergeTrainMember.create!(merge_train: train, job: member_job, position: index)
    end
    train
  end

  describe "#sample!" do
    it "bootstraps the cursor on the first tick without instrumenting existing history" do
      t0 = Time.current
      travel_to(t0 - 1.hour) { auto_merge_workflow(Factories.job_record(repository: repository)) }

      travel_to(t0) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_throughput_landing_units_total{")
    end

    it "counts a succeeded auto_merge Workflow as one auto_merge landing unit and one landed Job" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! } # bootstrap

      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      travel_to(t0 + 2.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_throughput_landing_units_total{unit_type="auto_merge"} 1')
      expect(rendered).to include("syrus_throughput_jobs_landed_total 1")
    end

    it "does not count a failed auto_merge Workflow" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository), state: "failed") }
      travel_to(t0 + 2.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).not_to include("syrus_throughput_landing_units_total{")
    end

    it "counts a succeeded merge_train as one merge_train landing unit and one landed Job per member" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) { succeeded_merge_train(member_count: 3) }
      travel_to(t0 + 2.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_throughput_landing_units_total{unit_type="merge_train"} 1')
      expect(rendered).to include("syrus_throughput_jobs_landed_total 3")
    end

    it "accumulates auto_merge and merge_train units into the same jobs_landed_total across ticks" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) do
        auto_merge_workflow(Factories.job_record(repository: repository))
        succeeded_merge_train(member_count: 2)
      end
      travel_to(t0 + 2.minutes) { described_class.sample! }

      travel_to(t0 + 3.minutes) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      travel_to(t0 + 4.minutes) { described_class.sample! }

      described_class.refresh_gauges!

      rendered = Syrus::Metrics.render
      expect(rendered).to include('syrus_throughput_landing_units_total{unit_type="auto_merge"} 2')
      expect(rendered).to include('syrus_throughput_landing_units_total{unit_type="merge_train"} 1')
      expect(rendered).to include("syrus_throughput_jobs_landed_total 4")
    end

    it "does not double-count a landing attempt already instrumented on a prior tick" do
      t0 = Time.current
      travel_to(t0) { described_class.sample! }

      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      travel_to(t0 + 2.minutes) { described_class.sample! }
      travel_to(t0 + 3.minutes) { described_class.sample! }

      described_class.refresh_gauges!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_throughput_landing_units_total{unit_type="auto_merge"} 1')
    end

    it "degrades one failing source without raising" do
      t0 = Time.current.change(usec: 0)
      travel_to(t0) { described_class.sample! }
      failed_cursor = cache.read(described_class::CACHE_KEY).dig("cursor", "auto_merge_through")
      allow(Workflow).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "no such table")

      travel_to(t0 + 1.minute) { expect { described_class.sample! }.not_to raise_error }

      checkpoint = cache.read(described_class::CACHE_KEY)
      expect(checkpoint.dig("cursor", "auto_merge_through")).to eq(failed_cursor)
      expect(checkpoint.dig("cursor", "merge_train_through")).to eq((t0 + 1.minute).iso8601(6))
    end

    it "retries an auto_merge interval after its query recovers" do
      t0 = Time.current.change(usec: 0)
      travel_to(t0) { described_class.sample! }
      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      allow(Workflow).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "temporarily unavailable")
      travel_to(t0 + 2.minutes) { described_class.sample! }

      allow(Workflow).to receive(:where).and_call_original
      travel_to(t0 + 3.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_throughput_landing_units_total{unit_type="auto_merge"} 1')
    end

    it "leaves the merge_train cursor and totals untouched when its member query fails" do
      t0 = Time.current.change(usec: 0)
      travel_to(t0) { described_class.sample! }
      travel_to(t0 + 1.minute) { succeeded_merge_train(member_count: 2) }
      allow(MergeTrainMember).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "temporarily unavailable")

      travel_to(t0 + 2.minutes) { described_class.sample! }

      checkpoint = cache.read(described_class::CACHE_KEY)
      expect(checkpoint.dig("cursor", "merge_train_through")).to eq(t0.iso8601(6))
      expect(checkpoint.dig("totals", "landing_units_total")).to be_nil
      expect(checkpoint.dig("totals", "jobs_landed_total")).to be_nil
    end

    it "persists cursor and totals in one versioned checkpoint write" do
      t0 = Time.current.change(usec: 0)
      travel_to(t0) { described_class.sample! }
      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      allow(cache).to receive(:write).and_call_original

      travel_to(t0 + 2.minutes) { described_class.sample! }

      expect(cache).to have_received(:write).once.with(
        described_class::CACHE_KEY,
        hash_including(
          "version" => described_class::CHECKPOINT_VERSION,
          "cursor" => hash_including("auto_merge_through" => (t0 + 2.minutes).iso8601(6)),
          "totals" => hash_including("jobs_landed_total" => 1)
        ),
        expires_in: described_class::CURSOR_TTL
      )
    end

    it "retries the interval without double-counting when the checkpoint write fails" do
      t0 = Time.current.change(usec: 0)
      travel_to(t0) { described_class.sample! }
      travel_to(t0 + 1.minute) { auto_merge_workflow(Factories.job_record(repository: repository)) }
      fail_write = true
      allow(cache).to receive(:write).and_wrap_original do |method, key, *args, **kwargs|
        raise "checkpoint unavailable" if fail_write && key == described_class::CACHE_KEY

        method.call(key, *args, **kwargs)
      end

      travel_to(t0 + 2.minutes) do
        expect { described_class.sample! }.to raise_error("checkpoint unavailable")
      end
      expect(cache.read(described_class::CACHE_KEY).dig("cursor", "auto_merge_through")).to eq(t0.iso8601(6))

      fail_write = false
      travel_to(t0 + 3.minutes) { described_class.sample! }
      travel_to(t0 + 4.minutes) { described_class.sample! }
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include('syrus_throughput_landing_units_total{unit_type="auto_merge"} 1')
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_throughput_landing_units_total")
    end
  end
end
