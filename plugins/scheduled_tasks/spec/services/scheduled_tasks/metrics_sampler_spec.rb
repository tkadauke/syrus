require "rails_helper"

RSpec.describe ScheduledTasks::MetricsSampler do
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  around do |example|
    original = Syrus::Metrics.registry
    Syrus::Metrics.reset!
    Syrus::Metrics.declare_plugin("scheduled_tasks") { gauge :autopaused_total }
    example.run
  ensure
    Syrus::Metrics.instance_variable_set(:@registry, original)
  end

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def task(state:, archived_at: nil)
    ScheduledTasks::Task.create!(
      user: user, repository: repository, name: "Task", prompt: "Do the thing.",
      kind: "cron", cron_expression: "0 9 * * 1", minute_offset: 5, pr_pileup_policy: "skip",
      state: state, archived_at: archived_at
    )
  end

  describe ".sample!/.refresh_gauges!" do
    it "reports nothing rather than zero when no sample has been taken" do
      expect(described_class.refresh_gauges!).to be(false)
      expect(Syrus::Metrics.render).not_to include("syrus_scheduled_tasks_autopaused_total")
    end

    it "counts currently auto-paused tasks" do
      task(state: "auto_paused")
      task(state: "auto_paused")
      task(state: "scheduled")
      task(state: "paused")

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_scheduled_tasks_autopaused_total 2")
    end

    it "excludes an archived auto-paused task" do
      task(state: "auto_paused", archived_at: Time.current)

      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_scheduled_tasks_autopaused_total 0")
    end

    it "reflects the latest sample rather than accumulating -- this is a gauge, not a counter" do
      task(state: "auto_paused")
      described_class.sample!
      described_class.refresh_gauges!
      expect(Syrus::Metrics.render).to include("syrus_scheduled_tasks_autopaused_total 1")

      ScheduledTasks::Task.update_all(state: "scheduled")
      described_class.sample!
      described_class.refresh_gauges!

      expect(Syrus::Metrics.render).to include("syrus_scheduled_tasks_autopaused_total 0")
    end
  end
end
