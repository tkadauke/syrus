require "rails_helper"

RSpec.describe "API: POST /api/v1/app/admin/platform_polling/start", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  def build_polling_stub
    @polling_stub_klass = Class.new(PlatformPollingJob) do
      def self.name = "FakePlatformPollingJob"

      private

      def configured? = true
    end
  end

  def parse_body
    JSON.parse(response.body)
  end

  after do
    next unless @polling_stub_klass

    PlatformPollingJob.instance_variable_get(:@registry).delete(@polling_stub_klass)
  end

  it "401s when signed out" do
    post "/api/v1/app/admin/platform_polling/start"

    expect(response).to have_http_status(:unauthorized)
  end

  it "403s for non-admin users" do
    sign_in_as(non_admin)

    post "/api/v1/app/admin/platform_polling/start"

    expect(response).to have_http_status(:forbidden)
  end

  context "when signed in as admin" do
    before { sign_in_as(admin) }

    it "returns started: [] when no subclasses are registered" do
      allow(PlatformPollingJob).to receive(:registry).and_return([])

      post "/api/v1/app/admin/platform_polling/start"

      expect(response).to have_http_status(:ok)
      expect(parse_body["started"]).to eq([])
    end

    context "with SolidQueue tables available" do
      before { ensure_solid_queue_test_tables! }
      after  { clear_solid_queue_test_tables! }

      it "enqueues registered subclasses not already running and returns their names" do
        stub_klass = build_polling_stub
        allow(PlatformPollingJob).to receive(:registry).and_return([stub_klass])
        allow(stub_klass).to receive(:perform_later)

        post "/api/v1/app/admin/platform_polling/start"

        expect(response).to have_http_status(:ok)
        expect(parse_body["started"]).to eq(["FakePlatformPollingJob"])
        expect(stub_klass).to have_received(:perform_later)
      end

      it "skips subclasses that already have an unfinished job" do
        stub_klass = build_polling_stub
        allow(PlatformPollingJob).to receive(:registry).and_return([stub_klass])
        SolidQueue::Job.create!(
          class_name: "FakePlatformPollingJob",
          queue_name: "default",
          priority: 0,
          arguments: "{}"
        )
        allow(stub_klass).to receive(:perform_later)

        post "/api/v1/app/admin/platform_polling/start"

        expect(response).to have_http_status(:ok)
        expect(parse_body["started"]).to eq([])
        expect(stub_klass).not_to have_received(:perform_later)
      end
    end
  end
end
