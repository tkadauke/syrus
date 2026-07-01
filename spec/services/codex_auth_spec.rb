require "rails_helper"
require "tmpdir"

RSpec.describe CodexAuth do
  let(:auth_json) { Factories.codex_auth_json(access_token: "access-token") }
  let(:user) { Factories.user(codex_api_key: "sk-test", codex_auth_json: auth_json) }

  describe ".with_refresh_lock" do
    it "does not reload users in api_key mode" do
      stale_user = User.find(user.id)
      user.update!(name: "Updated")

      described_class.with_refresh_lock(user: stale_user) do
        expect(stale_user.name).not_to eq("Updated")
      end
    end

    it "reloads ChatGPT auth before yielding" do
      user.update!(codex_auth_mode: "chatgpt_login")
      stale_user = User.find(user.id)
      user.update!(codex_auth_json: Factories.codex_auth_json(access_token: "fresh-access-token"))

      described_class.with_refresh_lock(user: stale_user) do
        expect(stale_user.codex_auth_json).to include("fresh-access-token")
      end
    end
  end

  describe "#prepare!" do
    it "returns the API key and does not run login in api_key mode" do
      called = false
      auth = described_class.new(
        user: user,
        codex_home: "/tmp/codex-home",
        runner: ->(**) { called = true }
      )

      result = auth.prepare!

      expect(result.api_key).to eq("sk-test")
      expect(called).to be(false)
    end

    it "requires an API key in api_key mode" do
      user.update!(codex_api_key: nil)

      expect {
        described_class.new(user: user, codex_home: "/tmp/codex-home").prepare!
      }.to raise_error(CodexAuth::Error, /API key/)
    end

    it "writes auth.json into CODEX_HOME in chatgpt_login mode" do
      user.update!(codex_auth_mode: "chatgpt_login")
      received = nil
      Dir.mktmpdir do |home|
        auth = described_class.new(
          user: user,
          codex_home: home,
          runner: ->(**kwargs) { received = kwargs }
        )

        result = auth.prepare!

        expect(result.api_key).to be_nil
        expected_json = JSON.pretty_generate(JSON.parse(auth_json)) + "\n"
        expect(received).to eq(codex_home: home, auth_json: expected_json)
        expect(File.directory?(home)).to be(true)
      end
    end

    it "requires auth.json in chatgpt_login mode" do
      user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: nil)

      expect {
        described_class.new(user: user, codex_home: "/tmp/codex-home").prepare!
      }.to raise_error(CodexAuth::Error, /auth\.json/)
    end

    it "rejects invalid auth.json" do
      user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: "{")

      expect {
        described_class.new(user: user, codex_home: "/tmp/codex-home").prepare!
      }.to raise_error(CodexAuth::Error, /not valid JSON/)
    end

    it "requires ChatGPT tokens in auth.json" do
      user.update!(codex_auth_mode: "chatgpt_login", codex_auth_json: JSON.generate("tokens" => {}))

      expect {
        described_class.new(user: user, codex_home: "/tmp/codex-home").prepare!
      }.to raise_error(CodexAuth::Error, /tokens\.id_token/)
    end
  end

  describe "default runner" do
    it "writes auth.json with owner-only permissions" do
      user.update!(codex_auth_mode: "chatgpt_login")
      Dir.mktmpdir do |home|
        described_class.new(user: user, codex_home: home).prepare!

        auth_path = File.join(home, "auth.json")
        expect(JSON.parse(File.read(auth_path))["tokens"]["access_token"]).to eq("access-token")
        expect(File.stat(auth_path).mode & 0o777).to eq(0o600)
      end
    end

    it "does not rewrite auth.json when the normalized contents are unchanged" do
      user.update!(codex_auth_mode: "chatgpt_login")
      Dir.mktmpdir do |home|
        described_class.new(user: user, codex_home: home).prepare!
        auth_path = File.join(home, "auth.json")

        expect(File).not_to receive(:write).with(auth_path, anything)

        described_class.new(user: user, codex_home: home).prepare!
      end
    end

    it "persists refreshed auth.json from CODEX_HOME back to the user" do
      user.update!(codex_auth_mode: "chatgpt_login")
      refreshed = Factories.codex_auth_json(access_token: "new-access-token")

      Dir.mktmpdir do |home|
        File.write(File.join(home, "auth.json"), refreshed)
        described_class.new(user: user, codex_home: home).persist_updated_auth_json

        expect(user.reload.codex_auth_json).to eq(JSON.pretty_generate(JSON.parse(refreshed)) + "\n")
      end
    end
  end
end
