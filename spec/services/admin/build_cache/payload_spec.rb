require "rails_helper"
require "aws-sdk-s3"

RSpec.describe Admin::BuildCache::Payload do
  around do |example|
    old_bucket = ENV["SCCACHE_BUCKET"]
    ENV["SCCACHE_BUCKET"] = "syrus-build-cache-test"
    example.run
  ensure
    ENV["SCCACHE_BUCKET"] = old_bucket
    Admin::BuildCache::Client.client_factory = nil
  end

  let(:user) { Factories.user }

  it "reports a friendly error instead of raising when the S3 call fails" do
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, "AccessDenied")
    Admin::BuildCache::Client.client_factory = -> { s3 }

    payload = described_class.new.show

    expect(payload[:stats]).to be_nil
    expect(payload[:stats_error]).to include("AccessDenied")
  end

  it "includes the current pending request separately from recent (non-pending) history" do
    AdminBuildCacheClearRequest.create!(user: user, scope: "full", reason: "cleanup")
    s3 = Aws::S3::Client.new(stub_responses: true, region: "auto")
    s3.stub_responses(:list_objects_v2, { is_truncated: false, contents: [] })
    Admin::BuildCache::Client.client_factory = -> { s3 }

    payload = described_class.new.show

    expect(payload[:pending_request]).to include(scope: "full", state: "pending")
    expect(payload[:recent_requests]).to eq([])
  end
end
