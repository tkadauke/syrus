require "rails_helper"

RSpec.describe "API: POST /api/v1/app/admin/platform_polling/start", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  def parse_body
    JSON.parse(response.body)
  end

  # Class.new(PlatformPollingJob) triggers the real `inherited` hook and
  # permanently appends the anonymous class to PlatformPollingJob.registry,
  # even when the example only ever reads through a stubbed `.registry`.
  # Without this cleanup the stub classes below leak into every later spec
  # in the same process and can flip PlatformPollingJob.start_all!'s real
  # (unstubbed) behavior elsewhere in the suite.
  after do
    PlatformPollingJob.registry.reject! { |klass| klass.name == "FakePlatformPollingJob" }
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
        stub_klass = Class.new(PlatformPollingJob) do
          def self.name = "FakePlatformPollingJob"

          private

          def configured? = true
        end
        allow(PlatformPollingJob).to receive(:registry).and_return([stub_klass])
        allow(stub_klass).to receive(:perform_later)

        post "/api/v1/app/admin/platform_polling/start"

        expect(response).to have_http_status(:ok)
        expect(parse_body["started"]).to eq(["FakePlatformPollingJob"])
        expect(stub_klass).to have_received(:perform_later)
      end

      it "skips subclasses that already have an unfinished job" do
        stub_klass = Class.new(PlatformPollingJob) do
          def self.name = "FakePlatformPollingJob"

          private

          def configured? = true
        end
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

      it "returns structured per-connector status detail alongside the started list" do
        stub_klass = Class.new(PlatformPollingJob) do
          def self.name = "FakePlatformPollingJob"

          private

          def configured? = true
        end
        allow(PlatformPollingJob).to receive(:registry).and_return([stub_klass])
        allow(stub_klass).to receive(:perform_later)

        post "/api/v1/app/admin/platform_polling/start"

        expect(response).to have_http_status(:ok)
        expect(parse_body["connectors"]).to include(
          hash_including("name" => "FakePlatformPollingJob", "status" => "started")
        )
      end

      context "with a plugin platform_delivery connector (e.g. Discord)" do
        let(:connector_job_class) do
          Class.new(PlatformPollingJob) do
            cattr_accessor :configured_flag
            self.configured_flag = true

            def self.name = "FakeDiscordConnectorJob"

            private

            def configured? = self.class.configured_flag
            def poll_once = nil
          end
        end

        let(:plugin_adapter_class) do
          job_class = connector_job_class
          Class.new do
            include Syrus::Plugin::PlatformDelivery
            define_singleton_method(:platform_key) { "discord" }
            define_singleton_method(:connector_job_class) { job_class }
            def deliver(message:, platform_identity:) = nil
          end
        end

        around do |ex|
          Syrus::PluginRegistry.reset!
          ex.run
          Syrus::PluginRegistry.reset!
          PlatformPollingJob.registry.delete(connector_job_class)
        end

        it "starts the plugin connector job alongside core pollers, reporting it in both started and connectors" do
          Syrus::PluginRegistry.register(
            name: "discord_plugin", version: "1.0.0",
            provides: { platform_delivery: plugin_adapter_class }
          )

          post "/api/v1/app/admin/platform_polling/start"

          expect(response).to have_http_status(:ok)
          expect(parse_body["started"]).to include("FakeDiscordConnectorJob")
          expect(parse_body["connectors"]).to include(
            hash_including("name" => "FakeDiscordConnectorJob", "status" => "started", "platform" => "discord")
          )
        end

        it "reports the plugin connector as already_running instead of starting a duplicate" do
          Syrus::PluginRegistry.register(
            name: "discord_plugin", version: "1.0.0",
            provides: { platform_delivery: plugin_adapter_class }
          )
          SolidQueue::Job.create!(
            class_name: connector_job_class.name,
            queue_name: "polling",
            priority: 0,
            arguments: "{}"
          )

          post "/api/v1/app/admin/platform_polling/start"

          expect(response).to have_http_status(:ok)
          expect(parse_body["started"]).not_to include("FakeDiscordConnectorJob")
          expect(parse_body["connectors"]).to include(
            hash_including("name" => "FakeDiscordConnectorJob", "status" => "already_running")
          )
        end
      end
    end
  end
end
