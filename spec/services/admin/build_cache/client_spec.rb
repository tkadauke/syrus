require "rails_helper"
require "aws-sdk-s3"

RSpec.describe Admin::BuildCache::Client do
  around do |example|
    old_bucket = ENV["SCCACHE_BUCKET"]
    old_prefix = ENV["SCCACHE_S3_KEY_PREFIX"]
    ENV["SCCACHE_BUCKET"] = "syrus-build-cache-test"
    ENV["SCCACHE_S3_KEY_PREFIX"] = nil
    example.run
  ensure
    ENV["SCCACHE_BUCKET"] = old_bucket
    ENV["SCCACHE_S3_KEY_PREFIX"] = old_prefix
    described_class.client_factory = nil
  end

  def stub_client
    Aws::S3::Client.new(stub_responses: true, region: "auto")
  end

  describe ".configured?" do
    it "is true when SCCACHE_BUCKET is set" do
      expect(described_class.configured?).to be(true)
    end

    it "is false when SCCACHE_BUCKET is unset" do
      ENV["SCCACHE_BUCKET"] = nil

      expect(described_class.configured?).to be(false)
    end
  end

  describe "#stats" do
    it "aggregates object count, total size, and oldest/newest object across pages" do
      s3 = stub_client
      described_class.client_factory = -> { s3 }
      s3.stub_responses(:list_objects_v2, [
        {
          is_truncated: true,
          next_continuation_token: "page-2",
          contents: [
            { key: "a", size: 100, last_modified: 3.days.ago },
            { key: "b", size: 200, last_modified: 1.day.ago }
          ]
        },
        {
          is_truncated: false,
          contents: [
            { key: "c", size: 50, last_modified: 5.days.ago }
          ]
        }
      ])

      stats = described_class.new.stats

      expect(stats.object_count).to eq(3)
      expect(stats.total_size_bytes).to eq(350)
      expect(stats.oldest_object.key).to eq("c")
      expect(stats.newest_object.key).to eq("b")
      expect(stats.truncated).to be(false)
    end

    it "returns zeroed stats for an empty bucket" do
      s3 = stub_client
      described_class.client_factory = -> { s3 }
      s3.stub_responses(:list_objects_v2, { is_truncated: false, contents: [] })

      stats = described_class.new.stats

      expect(stats.object_count).to eq(0)
      expect(stats.total_size_bytes).to eq(0)
      expect(stats.oldest_object).to be_nil
      expect(stats.newest_object).to be_nil
    end
  end

  describe "#clear_all!" do
    it "deletes every object and reports the freed bytes" do
      s3 = stub_client
      described_class.client_factory = -> { s3 }
      s3.stub_responses(:list_objects_v2, {
        is_truncated: false,
        contents: [
          { key: "a", size: 100, last_modified: 3.days.ago },
          { key: "b", size: 200, last_modified: 1.day.ago }
        ]
      })
      delete_calls = []
      s3.stub_responses(:delete_objects, ->(context) {
        delete_calls << context.params
        {}
      })

      result = described_class.new.clear_all!

      expect(result.deleted_count).to eq(2)
      expect(result.bytes_freed).to eq(300)
      expect(delete_calls.first[:delete][:objects].map { |o| o[:key] }).to contain_exactly("a", "b")
    end
  end

  describe "#clear_older_than!" do
    it "deletes only objects older than the given number of days" do
      s3 = stub_client
      described_class.client_factory = -> { s3 }
      s3.stub_responses(:list_objects_v2, {
        is_truncated: false,
        contents: [
          { key: "old", size: 100, last_modified: 10.days.ago },
          { key: "new", size: 200, last_modified: 1.hour.ago }
        ]
      })
      delete_calls = []
      s3.stub_responses(:delete_objects, ->(context) {
        delete_calls << context.params
        {}
      })

      result = described_class.new.clear_older_than!(5)

      expect(result.deleted_count).to eq(1)
      expect(result.bytes_freed).to eq(100)
      expect(delete_calls.first[:delete][:objects].map { |o| o[:key] }).to eq([ "old" ])
    end
  end
end
