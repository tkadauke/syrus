require "rails_helper"

RSpec.describe PrProvenanceMarker do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, issue_number: 42) }

  describe ".stamp" do
    it "embeds kind and job_id as an HTML comment" do
      marker = described_class.stamp(kind: "syrus_promotion", job: job)

      expect(marker).to eq("<!-- syrus-provenance:kind=syrus_promotion;job_id=#{job.id} -->")
    end

    it "raises for a kind that is never Syrus-stamped" do
      expect {
        described_class.stamp(kind: "manual_hotfix", job: job)
      }.to raise_error(ArgumentError, /unknown provenance kind/)

      expect {
        described_class.stamp(kind: "external_unknown", job: job)
      }.to raise_error(ArgumentError, /unknown provenance kind/)
    end
  end

  describe ".parse" do
    it "round-trips a stamped body" do
      body = "Some PR description.\n\n#{described_class.stamp(kind: 'syrus_job_export', job: job)}"

      expect(described_class.parse(body)).to eq("kind" => "syrus_job_export", "job_id" => job.id.to_s)
    end

    it "returns nil for a body with no marker" do
      expect(described_class.parse("Just a regular PR body.")).to be_nil
    end

    it "returns nil for a blank body" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("")).to be_nil
    end

    it "returns nil when the marker has no kind field" do
      expect(described_class.parse("<!-- syrus-provenance:job_id=1 -->")).to be_nil
    end
  end
end
