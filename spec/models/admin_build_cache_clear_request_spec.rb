require "rails_helper"
require "aws-sdk-s3"

RSpec.describe AdminBuildCacheClearRequest do
  around do |example|
    old_bucket = ENV["SCCACHE_BUCKET"]
    ENV["SCCACHE_BUCKET"] = "syrus-build-cache-test"
    example.run
  ensure
    ENV["SCCACHE_BUCKET"] = old_bucket
    Admin::BuildCache::Client.client_factory = nil
  end

  let(:user) { Factories.user }

  def stub_s3(objects: [])
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, { is_truncated: false, contents: objects })
    s3.stub_responses(:delete_objects, {})
    Admin::BuildCache::Client.client_factory = -> { s3 }
    s3
  end

  it "is invalid without a reason" do
    request = described_class.new(user: user, scope: "full", reason: "")

    expect(request).not_to be_valid
    expect(request.errors[:reason]).to be_present
  end

  it "is invalid with an unknown scope" do
    request = described_class.new(user: user, scope: "bogus", reason: "cleanup")

    expect(request).not_to be_valid
    expect(request.errors[:scope]).to be_present
  end

  it "requires a positive older_than_days for a partial scope" do
    request = described_class.new(user: user, scope: "partial", reason: "cleanup")

    expect(request).not_to be_valid
    expect(request.errors[:older_than_days]).to be_present
  end

  it "clears older_than_days for a full scope even if supplied" do
    request = described_class.new(user: user, scope: "full", older_than_days: 30, reason: "cleanup")
    request.valid?

    expect(request.older_than_days).to be_nil
  end

  it "is invalid when the build cache bucket is not configured" do
    ENV["SCCACHE_BUCKET"] = nil
    request = described_class.new(user: user, scope: "full", reason: "cleanup")

    expect(request).not_to be_valid
    expect(request.errors[:base]).to include("build cache bucket is not configured")
  end

  it "rejects a new request while one is already pending" do
    described_class.create!(user: user, scope: "full", reason: "first")
    second = described_class.new(user: user, scope: "full", reason: "second")

    expect(second).not_to be_valid
    expect(second.errors[:base]).to include("another clear request is already pending")
  end

  describe "#confirm!" do
    it "executes a full clear, records the result, and logs an AdminAction" do
      stub_s3(objects: [ { key: "a", size: 100, last_modified: 3.days.ago } ])
      request = described_class.create!(user: user, scope: "full", reason: "cleanup")

      expect {
        expect(request.confirm!(user: user)).to be(true)
      }.to change(AdminAction, :count).by(1)

      expect(request.reload.state).to eq("confirmed")
      expect(request.confirmed_at).to be_present
      expect(request.result).to eq("deleted_count" => 1, "bytes_freed" => 100, "truncated" => false)

      action = AdminAction.last
      expect(action.action).to eq("build_cache_clear")
      expect(action.params["reason"]).to eq("cleanup")
      expect(action.params["deleted_count"]).to eq(1)
    end

    it "executes a partial clear scoped to older_than_days" do
      stub_s3(objects: [
        { key: "old", size: 100, last_modified: 10.days.ago },
        { key: "new", size: 200, last_modified: 1.hour.ago }
      ])
      request = described_class.create!(user: user, scope: "partial", older_than_days: 5, reason: "trim")

      request.confirm!(user: user)

      expect(request.reload.result).to eq("deleted_count" => 1, "bytes_freed" => 100, "truncated" => false)
    end

    it "does nothing and returns false when the request is not pending" do
      stub_s3
      request = described_class.create!(user: user, scope: "full", reason: "cleanup")
      request.update!(state: "cancelled", cancelled_at: Time.current)

      expect(request.confirm!(user: user)).to be(false)
      expect(AdminAction.count).to eq(0)
    end
  end

  describe "#cancel!" do
    it "cancels a pending request" do
      request = described_class.create!(user: user, scope: "full", reason: "cleanup")

      expect(request.cancel!).to be_truthy
      expect(request.reload.state).to eq("cancelled")
      expect(request.cancelled_at).to be_present
    end

    it "returns false for a non-pending request" do
      request = described_class.create!(user: user, scope: "full", reason: "cleanup")
      request.update!(state: "cancelled", cancelled_at: Time.current)

      expect(request.cancel!).to be(false)
    end
  end
end
