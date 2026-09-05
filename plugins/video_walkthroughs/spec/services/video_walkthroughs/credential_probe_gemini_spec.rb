require "rails_helper"

RSpec.describe VideoWalkthroughs::CredentialProbe do
  let(:client) { instance_double(VideoWalkthroughs::Gemini::Client) }
  let(:captured_keys) { [] }

  around do |example|
    original = VideoWalkthroughs::CredentialProbe.client_factory
    VideoWalkthroughs::CredentialProbe.client_factory = lambda do |api_key:|
      captured_keys << api_key
      client
    end
    example.run
  ensure
    VideoWalkthroughs::CredentialProbe.client_factory = original
  end

  describe ".key" do
    it "refuses a blank key without calling Google" do
      result = VideoWalkthroughs::CredentialProbe.key(key: "  ")

      expect(result.ok).to be false
      expect(result.message).to eq("Paste a key to test it.")
      expect(captured_keys).to be_empty
    end

    it "is ok when a video-capable flash model is available" do
      allow(client).to receive(:list_models).and_return(%w[ gemini-3.5-flash gemini-embedding-001 ])

      result = VideoWalkthroughs::CredentialProbe.key(key: "AIza-unsaved")

      expect(result.ok).to be true
      expect(result.message).to include("gemini-3.5-flash")
      expect(result.details).to eq(model: "gemini-3.5-flash", models_available: 2)
      expect(captured_keys).to eq([ "AIza-unsaved" ])
    end

    it "is not ok when the key works but no video-capable model is available" do
      allow(client).to receive(:list_models).and_return(%w[ gemini-embedding-001 text-bison ])

      result = VideoWalkthroughs::CredentialProbe.key(key: "AIza-restricted")

      expect(result.ok).to be false
      expect(result.message).to include("no video-capable Gemini flash model")
      expect(result.details).to eq(models_available: 2)
    end

    it "reports a rejected key on AuthError" do
      allow(client).to receive(:list_models).and_raise(VideoWalkthroughs::Gemini::Client::AuthError, "API key not valid.")

      result = VideoWalkthroughs::CredentialProbe.key(key: "AIza-bad")

      expect(result.ok).to be false
      expect(result.message).to include("Google rejected this key")
    end

    it "reports throttling on RateLimited" do
      allow(client).to receive(:list_models).and_raise(VideoWalkthroughs::Gemini::Client::RateLimited, "quota")

      result = VideoWalkthroughs::CredentialProbe.key(key: "AIza-busy")

      expect(result.ok).to be false
      expect(result.message).to include("throttled")
    end

    it "reports an unreachable Google on network errors" do
      allow(client).to receive(:list_models).and_raise(SocketError, "getaddrinfo failed")

      result = VideoWalkthroughs::CredentialProbe.key(key: "AIza-offline")

      expect(result.ok).to be false
      expect(result.message).to include("Could not reach Google")
    end
  end

  # Core dispatches to this probe only because the enabled plugin registered
  # it, so these examples exercise the registration as much as the probe.
  describe "through CredentialProbe.call, once the plugin has registered it" do
    before { PluginRecord.find_or_create_by!(name: "video_walkthroughs").update!(enabled: true, disableable: true) }

    it "probes the stored key through the same path" do
      allow(client).to receive(:list_models).and_return(%w[ gemini-3.5-flash ])
      user = Factories.user(gemini_api_key: "AIza-stored")

      result = ::CredentialProbe.call(user: user, credential: "gemini_api_key")

      expect(result.ok).to be true
      expect(result.credential).to eq("gemini_api_key")
      expect(result.details).to include(model: "gemini-3.5-flash")
      expect(captured_keys).to eq([ "AIza-stored" ])
    end

    it "reports a missing key without calling Google" do
      user = Factories.user(gemini_api_key: nil)

      result = ::CredentialProbe.call(user: user, credential: "gemini_api_key")

      expect(result.ok).to be false
      expect(result.message).to eq("Gemini API key is not configured.")
      expect(captured_keys).to be_empty
    end
  end
end
