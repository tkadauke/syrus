require "rails_helper"

RSpec.describe K8sCluster::AgenticAudit do
  describe ".log!" do
    it "logs a structured success entry without the raw result payload" do
      allow(Rails.logger).to receive(:info)

      described_class.log!(cluster_id: 7, tool_name: "k8s_cluster_pods", params: { cluster_id: 7 }, result: { available: true, pods: [ { name: "web-1" } ] })

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include("k8s_cluster_agentic_call")
        expect(message).to include("\"cluster_id\":7")
        expect(message).to include("\"tool\":\"k8s_cluster_pods\"")
        expect(message).to include("\"outcome\":\"success\"")
        expect(message).not_to include("web-1")
      end
    end

    it "logs the curated before/after summary for a write tool result without the full payload" do
      allow(Rails.logger).to receive(:info)

      result = {
        available: true,
        deployment: "web",
        namespace: "default",
        before: { replicas: 2 },
        after: { replicas: 4 }
      }
      described_class.log!(cluster_id: 7, tool_name: "k8s_cluster_scale_deployment", params: { cluster_id: 7 }, result: result)

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include("\"before\":{\"replicas\":2}")
        expect(message).to include("\"after\":{\"replicas\":4}")
      end
    end

    it "logs a structured error entry" do
      allow(Rails.logger).to receive(:info)

      described_class.log!(cluster_id: 7, tool_name: "k8s_cluster_pods", params: { cluster_id: 7 }, error: K8sCluster::AgenticAccess::AccessDisabled.new("nope"))

      expect(Rails.logger).to have_received(:info) do |message|
        expect(message).to include("\"outcome\":\"error\"")
        expect(message).to include("AccessDisabled: nope")
      end
    end

    it "never raises out of a logging failure" do
      allow(Rails.logger).to receive(:info).and_raise(StandardError, "boom")
      allow(Rails.logger).to receive(:error)

      expect { described_class.log!(cluster_id: 7, tool_name: "t", params: {}, result: {}) }.not_to raise_error
    end
  end
end
