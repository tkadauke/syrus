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
      allow(Workflow).to receive(:where).and_raise(ActiveRecord::StatementInvalid, "no such table")
      travel_to(Time.current) { described_class.sample! } # bootstrap
      travel_to(Time.current + 1.minute) { expect { described_class.sample! }.not_to raise_error }
    end
  end

  describe "#refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_throughput_landing_units_total")
    end
  end
end
