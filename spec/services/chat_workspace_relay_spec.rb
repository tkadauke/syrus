require "rails_helper"
require "net/http"
require "socket"

RSpec.describe ChatWorkspaceRelay do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:token) { SecureRandom.hex(32) }

  let(:relay_port) do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    server.close
    port
  end

  before do
    ENV["SYRUS_WORKSPACE_RELAY_PORT"] = relay_port.to_s
    described_class.start!
  end

  after do
    described_class.stop!
    described_class.relay_address = nil
    ENV.delete("SYRUS_WORKSPACE_RELAY_PORT")
  end

  def get_relay(path_with_query, bearer: token)
    uri = URI("http://127.0.0.1:#{relay_port}#{path_with_query}")
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{bearer}" if bearer
    VCR.turned_off { Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) } }
  end

  describe ".start!" do
    it "sets relay_address to host:port" do
      expect(described_class.relay_address).to eq("127.0.0.1:#{relay_port}")
    end

    it "is idempotent: a second call does not raise or change relay_address" do
      first = described_class.relay_address
      described_class.start!
      expect(described_class.relay_address).to eq(first)
    end

    it "survives a Zeitwerk-style reload: restores relay_address after EADDRINUSE" do
      # Simulate what Rails code-reloading does: the pre-reload server thread
      # survives (holding the port), while class-level ivars are wiped.
      # We stop the existing server cleanly, then hold the port externally to
      # guarantee EADDRINUSE on the next TCPServer.new call — no GC uncertainty.
      described_class.stop!
      external_hold = TCPServer.new("127.0.0.1", relay_port)

      begin
        expect { described_class.start! }.not_to raise_error
        expect(described_class.relay_address).to eq("127.0.0.1:#{relay_port}")
      ensure
        external_hold.close
      end
    end
  end

  describe ".relay_address=" do
    it "injects a stub address without starting a server" do
      described_class.stop!
      described_class.relay_address = "10.0.0.1:9283"
      expect(described_class.relay_address).to eq("10.0.0.1:9283")
      described_class.relay_address = nil
    end
  end

  describe ".stop!" do
    it "clears relay_address" do
      described_class.stop!
      expect(described_class.relay_address).to be_nil
    end
  end

  describe "HTTP routes" do
    before do
      chat_session.update_columns(coding_relay_token: token)
      chat_session.chat_attachments.find_or_create_by!(attachable: repository)

      allow(ChatWorkspace).to receive(:file_tree).and_return({
        files: ["README.md", "app/main.rb"],
        checkout_branch: "syrus-chat-#{chat_session.id}"
      })
      allow(ChatWorkspace).to receive(:file_content).and_return({
        content: "# Widgets",
        binary: false,
        too_large: false
      })
      allow(ChatWorkspace).to receive(:coding_diff).and_return("--- a/README.md\n+++ b/README.md")
    end

    describe "GET /workspace/files" do
      it "returns file list and checkout_branch for an authenticated session" do
        res = get_relay("/workspace/files?session_id=#{chat_session.id}")

        expect(res.code).to eq("200")
        body = JSON.parse(res.body)
        expect(body["files"]).to include("README.md")
        expect(body["checkout_branch"]).to eq("syrus-chat-#{chat_session.id}")
      end

      it "returns 401 for a wrong bearer token" do
        res = get_relay("/workspace/files?session_id=#{chat_session.id}", bearer: "wrong")
        expect(res.code).to eq("401")
      end

      it "returns 401 when Authorization header is absent" do
        res = get_relay("/workspace/files?session_id=#{chat_session.id}", bearer: nil)
        expect(res.code).to eq("401")
      end

      it "returns 404 for an unknown session_id" do
        res = get_relay("/workspace/files?session_id=999999", bearer: "irrelevant")
        expect(res.code).to eq("404")
      end

      it "returns 400 when session_id is omitted" do
        res = get_relay("/workspace/files")
        expect(res.code).to eq("400")
      end
    end

    describe "GET /workspace/file" do
      it "returns file content with the path merged in" do
        res = get_relay("/workspace/file?session_id=#{chat_session.id}&path=README.md")

        expect(res.code).to eq("200")
        body = JSON.parse(res.body)
        expect(body["content"]).to eq("# Widgets")
        expect(body["binary"]).to eq(false)
        expect(body["path"]).to eq("README.md")
      end

      it "returns 404 when ChatWorkspace.file_content returns nil (path traversal or missing file)" do
        allow(ChatWorkspace).to receive(:file_content).and_return(nil)

        res = get_relay("/workspace/file?session_id=#{chat_session.id}&path=../../../etc/passwd")
        expect(res.code).to eq("404")
      end

      it "returns 422 when path parameter is blank" do
        res = get_relay("/workspace/file?session_id=#{chat_session.id}&path=")
        expect(res.code).to eq("422")
      end

      it "returns 401 for a wrong bearer token" do
        res = get_relay("/workspace/file?session_id=#{chat_session.id}&path=README.md", bearer: "bad")
        expect(res.code).to eq("401")
      end
    end

    describe "GET /workspace/diff" do
      it "returns diff, mode, and checkout_branch" do
        res = get_relay("/workspace/diff?session_id=#{chat_session.id}&mode=cumulative")

        expect(res.code).to eq("200")
        body = JSON.parse(res.body)
        expect(body["diff"]).to include("README.md")
        expect(body["mode"]).to eq("cumulative")
        expect(body["checkout_branch"]).to eq(chat_session.coding_checkout_branch)
      end

      it "accepts mode=turn" do
        res = get_relay("/workspace/diff?session_id=#{chat_session.id}&mode=turn")

        expect(res.code).to eq("200")
        expect(JSON.parse(res.body)["mode"]).to eq("turn")
        expect(ChatWorkspace).to have_received(:coding_diff).with(anything, anything, mode: :turn)
      end

      it "defaults to cumulative for an unrecognized mode value" do
        res = get_relay("/workspace/diff?session_id=#{chat_session.id}&mode=bogus")

        expect(res.code).to eq("200")
        expect(JSON.parse(res.body)["mode"]).to eq("cumulative")
      end

      it "returns 401 for a wrong bearer token" do
        res = get_relay("/workspace/diff?session_id=#{chat_session.id}&mode=cumulative", bearer: "bad")
        expect(res.code).to eq("401")
      end
    end
  end
end
