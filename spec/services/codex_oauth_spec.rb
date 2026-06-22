require "rails_helper"

RSpec.describe CodexOauth do
  describe ".begin" do
    it "builds an authorize URL with Codex CLI OAuth parameters and PKCE S256" do
      flow = described_class.begin(redirect_uri: "http://localhost:1455/auth/callback")

      uri = URI(flow.authorize_url)
      params = Rack::Utils.parse_query(uri.query)

      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(described_class::AUTHORIZE_URL)
      expect(params).to include(
        "client_id" => described_class::CLIENT_ID,
        "response_type" => "code",
        "redirect_uri" => "http://localhost:1455/auth/callback",
        "scope" => described_class::SCOPE,
        "code_challenge_method" => "S256",
        "id_token_add_organizations" => "true",
        "codex_cli_simplified_flow" => "true",
        "originator" => "codex_cli_rs",
        "state" => flow.state
      )
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(flow.verifier), padding: false)
      expect(params["code_challenge"]).to eq(expected)
    end

    it "produces a fresh verifier and state each call" do
      a = described_class.begin(redirect_uri: "http://localhost:1455/auth/callback")
      b = described_class.begin(redirect_uri: "http://localhost:1455/auth/callback")

      expect(a.verifier).not_to eq(b.verifier)
      expect(a.state).not_to eq(b.state)
    end
  end

  describe ".exchange" do
    let(:token_url) { described_class::TOKEN_URL }
    let(:token_response) do
      {
        id_token: "id-token",
        access_token: "access-token",
        refresh_token: "refresh-token"
      }
    end

    it "exchanges a code for Codex auth.json" do
      stub_request(:post, token_url)
        .with(
          body: hash_including(
            "grant_type" => "authorization_code",
            "code" => "the-code",
            "code_verifier" => "ver",
            "client_id" => described_class::CLIENT_ID
          ),
          headers: { "Content-Type" => "application/x-www-form-urlencoded" }
        )
        .to_return(status: 200, body: token_response.to_json, headers: { "Content-Type" => "application/json" })

      auth_json = described_class.exchange(
        code: "the-code",
        verifier: "ver",
        state: "st",
        redirect_uri: "http://localhost:1455/auth/callback"
      )

      parsed = JSON.parse(auth_json)
      expect(parsed).to include("auth_mode" => "chatgpt")
      expect(parsed["tokens"]).to include(
        "id_token" => "id-token",
        "access_token" => "access-token",
        "refresh_token" => "refresh-token"
      )
      expect(parsed["last_refresh"]).to be_present
    end

    it "splits and validates the paste-flow code#state form" do
      stub_request(:post, token_url)
        .with(body: hash_including("code" => "abc"))
        .to_return(status: 200, body: token_response.to_json, headers: { "Content-Type" => "application/json" })

      auth_json = described_class.exchange(
        code: "abc#session-state",
        verifier: "ver",
        state: "session-state",
        redirect_uri: "http://localhost:1455/auth/callback"
      )

      expect(JSON.parse(auth_json).dig("tokens", "access_token")).to eq("access-token")
    end

    it "accepts a pasted callback URL and validates its state query parameter" do
      stub_request(:post, token_url)
        .with(body: hash_including("code" => "url-code"))
        .to_return(status: 200, body: token_response.to_json, headers: { "Content-Type" => "application/json" })

      auth_json = described_class.exchange(
        code: "http://localhost:1455/auth/callback?code=url-code&state=session-state",
        verifier: "ver",
        state: "session-state",
        redirect_uri: "http://localhost:1455/auth/callback"
      )

      expect(JSON.parse(auth_json).dig("tokens", "refresh_token")).to eq("refresh-token")
    end

    it "raises when the pasted state does not match the session" do
      expect {
        described_class.exchange(
          code: "abc#wrong-state",
          verifier: "ver",
          state: "session-state",
          redirect_uri: "http://localhost:1455/auth/callback"
        )
      }.to raise_error(described_class::Error, /state did not match/)
    end

    it "raises a friendly error when the code is blank" do
      expect {
        described_class.exchange(code: "  ", verifier: "ver", state: "st", redirect_uri: "http://localhost:1455/auth/callback")
      }.to raise_error(described_class::Error, /Missing authorization code/)
    end

    it "raises with the provider error description on rejection" do
      stub_request(:post, token_url).to_return(
        status: 400,
        body: { error: "invalid_grant", error_description: "Code expired." }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect {
        described_class.exchange(code: "x", verifier: "v", state: "s", redirect_uri: "http://localhost:1455/auth/callback")
      }.to raise_error(described_class::Error, "Code expired.")
    end

    it "raises when required tokens are missing" do
      stub_request(:post, token_url).to_return(status: 200, body: { access_token: "access" }.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        described_class.exchange(code: "x", verifier: "v", state: "s", redirect_uri: "http://localhost:1455/auth/callback")
      }.to raise_error(described_class::Error, /id_token/)
    end
  end

  describe ".start_callback_listener" do
    before do
      server = TCPServer.new("localhost", 0)
      port = server.addr[1]
      server.close
      stub_const("#{described_class}::CALLBACK_PORT", port)
    end

    it "accepts one localhost callback, responds with friendly HTML, and broadcasts the callback URL" do
      user = Factories.user
      allow(AppEvents).to receive(:broadcast)

      expect(described_class.start_callback_listener(user: user, timeout: 2.seconds)).to be true

      socket = TCPSocket.new("localhost", described_class::CALLBACK_PORT)
      socket.write("GET /auth/callback?code=abc&state=session-state HTTP/1.1\r\nHost: localhost\r\n\r\n")
      response = socket.read
      socket.close

      expect(response).to include("200 OK")
      expect(response).to include("Authorization received")
      expect(AppEvents).to have_received(:broadcast).with(
        user: user,
        type: "codex_oauth.callback",
        resource: "credential",
        payload: { "code" => "#{described_class::PASTE_REDIRECT_URI}?code=abc&state=session-state" }
      )
    end

    it "returns false when the callback port is unavailable" do
      allow(Rails.logger).to receive(:warn)
      allow(TCPServer).to receive(:new).and_raise(Errno::EADDRINUSE)

      expect(described_class.start_callback_listener(user: Factories.user, timeout: 1.second)).to be false
      expect(Rails.logger).to have_received(:warn).with(/Codex OAuth localhost callback listener unavailable/)
    end
  end
end
