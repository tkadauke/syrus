require "rails_helper"

RSpec.describe Admin::RestartService do
  let(:admin) { Factories.user }
  let(:service) { described_class.new(actor: admin) }
  let(:cache_backend) { ActiveSupport::Cache::MemoryStore.new }

  before do
    # Test env's Rails.cache is :null_store (writes/reads are no-ops).
    # Delegate to a real per-example MemoryStore so poison-pill writes are observable.
    allow(Rails.cache).to receive(:write) { |*args, **kwargs| cache_backend.write(*args, **kwargs) }
    allow(Rails.cache).to receive(:read) { |*args, **kwargs| cache_backend.read(*args, **kwargs) }
  end

  describe "#request" do
    it "writes a poison-pill timestamp for the web role and logs the action" do
      expect {
        result = service.request(component: "web", source: "test")
        expect(result).to eq(initiated: true, component: "web", active_runs: 0)
      }.to change { AdminAction.where(action: "restart").count }.by(1)

      expect(Rails.cache.read("syrus:restart_web")).to be_a(Float)
      expect(Rails.cache.read("syrus:restart_worker")).to be_nil
    end

    it "writes poison-pill timestamps for both roles when component is all" do
      service.request(component: "all", source: "test")

      expect(Rails.cache.read("syrus:restart_web")).to be_a(Float)
      expect(Rails.cache.read("syrus:restart_worker")).to be_a(Float)
    end

    it "does not require an active-run check for web" do
      Factories.job # creates a queued Run

      result = service.request(component: "web", source: "test")

      expect(result[:initiated]).to be(true)
    end

    it "refuses to restart the worker with active runs unless forced" do
      Factories.job # creates a queued Run

      expect {
        result = service.request(component: "worker", source: "test")
        expect(result).to eq(initiated: false, component: "worker", active_runs: 1)
      }.not_to change { AdminAction.where(action: "restart").count }

      expect(Rails.cache.read("syrus:restart_worker")).to be_nil
    end

    it "restarts the worker with active runs when forced" do
      Factories.job

      result = service.request(component: "worker", force: true, source: "test")

      expect(result).to eq(initiated: true, component: "worker", active_runs: 1)
      expect(Rails.cache.read("syrus:restart_worker")).to be_a(Float)
    end

    it "raises for an unknown component" do
      expect { service.request(component: "database", source: "test") }
        .to raise_error(Admin::RestartService::InvalidComponent)
    end
  end
end
