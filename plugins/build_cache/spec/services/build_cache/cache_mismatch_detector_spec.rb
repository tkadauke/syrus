require "rails_helper"

RSpec.describe BuildCache::CacheMismatchDetector do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }

  describe ".check!" do
    it "files a warning when SCCACHE_BUCKET is configured but the cache reports local disk" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: { "SCCACHE_BUCKET" => "syrus-build-cache" },
          stats: { "cache_location" => "Local disk: \"/home/rails/.cache/sccache\"" }
        )
      }.to change(WorkflowWarning, :count).by(1)

      warning = WorkflowWarning.last
      expect(warning.kind).to eq("sccache_config_mismatch")
      expect(warning.title).to match(/local-disk cache/i)
    end

    it "does not warn about local disk when SCCACHE_BUCKET was not forwarded" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: {},
          stats: { "cache_location" => "Local disk: \"/home/rails/.cache/sccache\"" }
        )
      }.not_to change(WorkflowWarning, :count)
    end

    it "does not warn when the cache location is the shared backend" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: { "SCCACHE_BUCKET" => "syrus-build-cache" },
          stats: { "cache_location" => "S3, bucket: syrus-build-cache" }
        )
      }.not_to change(WorkflowWarning, :count)
    end

    it "files a warning when SCCACHE_BASEDIRS was forwarded but stats report an empty basedirs list" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: { "SCCACHE_BASEDIRS" => "/syrus-home/.syrus/workflows/1" },
          stats: { "basedirs" => [] }
        )
      }.to change(WorkflowWarning, :count).by(1)

      warning = WorkflowWarning.last
      expect(warning.kind).to eq("sccache_config_mismatch")
      expect(warning.title).to match(/basedirs/i)
    end

    it "does not warn about basedirs when SCCACHE_BASEDIRS was not forwarded" do
      expect {
        described_class.check!(workflow: workflow, step: step, env: {}, stats: { "basedirs" => [] })
      }.not_to change(WorkflowWarning, :count)
    end

    it "does not warn when basedirs were actually applied" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: { "SCCACHE_BASEDIRS" => "/syrus-home/.syrus/workflows/1" },
          stats: { "basedirs" => [ "/syrus-home/.syrus/workflows/1" ] }
        )
      }.not_to change(WorkflowWarning, :count)
    end

    it "never raises, even on malformed stats" do
      expect {
        described_class.check!(
          workflow: workflow, step: step,
          env: { "SCCACHE_BUCKET" => "x", "SCCACHE_BASEDIRS" => "/y" },
          stats: "not a hash"
        )
      }.not_to raise_error
    end
  end
end
