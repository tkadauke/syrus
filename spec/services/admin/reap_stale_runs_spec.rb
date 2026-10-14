require "rails_helper"

RSpec.describe Admin::ReapStaleRuns do
  describe ".call" do
    it "always executes the unified reconciler inline with repairs, through the concurrency-guarded entry point" do
      result = WorkEngine::Reconciler::Result.new(
        "spec",
        Time.current,
        instance_double(WorkEngine::Reconciler::Snapshot, as_json: {}),
        [ instance_double(WorkEngine::Reconciler::Issue) ],
        [],
        [ instance_double(WorkEngine::RepairExecutor::Execution) ]
      )
      expect(WorkEngine::Reconciler).to receive(:call_locked!)
        .with(source: "test-source", execute_repairs: true)
        .and_return(result)

      outcome = described_class.call(source: "test-source")

      expect(outcome.message).to eq("WorkEngine reconciler ran inline.")
      expect(outcome.issues_count).to eq(1)
      expect(outcome.repairs_count).to eq(1)
    end

    it "clears the admin stuck snapshot after a reconciliation run" do
      result = WorkEngine::Reconciler::Result.new(
        "spec",
        Time.current,
        instance_double(WorkEngine::Reconciler::Snapshot, as_json: {}),
        [],
        [],
        []
      )
      allow(WorkEngine::Reconciler).to receive(:call_locked!).and_return(result)
      allow(Admin::StuckItemsCache).to receive(:clear!).and_call_original

      described_class.call(source: "test-source")

      expect(Admin::StuckItemsCache).to have_received(:clear!)
    end

    it "reports a skip instead of running when a concurrent reconciliation already holds the lock" do
      allow(WorkEngine::Reconciler).to receive(:call_locked!).and_return(nil)
      allow(Admin::StuckItemsCache).to receive(:clear!).and_call_original

      outcome = described_class.call(source: "test-source")

      expect(outcome.message).to match(/concurrent reconciliation/i)
      expect(outcome.issues_count).to eq(0)
      expect(outcome.repairs_count).to eq(0)
      expect(Admin::StuckItemsCache).not_to have_received(:clear!)
    end

    it "does not consult any feature flag" do
      result = WorkEngine::Reconciler::Result.new(
        "spec", Time.current,
        instance_double(WorkEngine::Reconciler::Snapshot, as_json: {}),
        [], [], []
      )
      allow(WorkEngine::Reconciler).to receive(:call_locked!).and_return(result)

      expect(Feature).not_to receive(:enabled?)
      expect(Feature).not_to receive(:find_by)

      described_class.call(source: "test-source")
    end
  end
end
