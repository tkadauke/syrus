require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::CronJobs do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def cron_job(name: "nightly-backup", suspend: false)
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "schedule" => "0 2 * * *", "suspend" => suspend },
      "status" => { "active" => [ { "name" => "nightly-backup-123" } ], "lastScheduleTime" => "2026-01-02T02:00:00Z" }
    }
  end

  describe "#list" do
    it "lists cron jobs with schedule and active-run counts" do
      stub_batch_discovery(base)
      stub_kube_get("#{base}/apis/batch/v1/namespaces/default/cronjobs", { "items" => [ cron_job ] })

      row = described_class.new(cluster).list(namespace: "default")[:cron_jobs].first

      expect(row[:schedule]).to eq("0 2 * * *")
      expect(row[:suspended]).to be(false)
      expect(row[:active_count]).to eq(1)
      expect(row[:last_schedule_time]).to eq("2026-01-02T02:00:00Z")
    end
  end

  describe "#describe" do
    it "returns the raw cron job object" do
      stub_batch_discovery(base)
      stub_kube_get("#{base}/apis/batch/v1/namespaces/default/cronjobs/nightly-backup", cron_job)

      payload = described_class.new(cluster).describe("nightly-backup", namespace: "default")

      expect(payload[:cron_job]["metadata"]["name"]).to eq("nightly-backup")
    end
  end
end
