require "rails_helper"

RSpec.describe ClaudeOauth do
  describe ".begin" do
    it "builds an authorize URL with PKCE S256 and returns the verifier + state" do
      flow = described_class.begin(redirect_uri: "http://localhost:3000/oauth/claude/callback")

      uri = URI(flow.authorize_url)
      params = Rack::Utils.parse_query(uri.query)

      expect("#{uri.scheme}://#{uri.host}#{uri.path}").to eq(described_class::AUTHORIZE_URL)
      expect(params).to include(
        "client_id" => described_class::CLIENT_ID,
        "response_type" => "code",
        "redirect_uri" => "http://localhost:3000/oauth/claude/callback",
        "scope" => described_class::SCOPE,
        "code_challenge_method" => "S256",
        "state" => flow.state
      )
      expect(params["code_challenge"]).to be_present
      # Challenge is the base64url(sha256(verifier)), no padding.
      expected = Base64.urlsafe_encode64(Digest::SHA256.digest(flow.verifier), padding: false)
      expect(params["code_challenge"]).to eq(expected)
    end

    it "produces a fresh verifier and state each call" do
      a = described_class.begin(redirect_uri: "http://x/cb")
      b = described_class.begin(redirect_uri: "http://x/cb")

      expect(a.verifier).not_to eq(b.verifier)
      expect(a.state).not_to eq(b.state)
    end
  end

  describe ".looks_like_token?" do
    it "returns true for sk-ant- prefixed values" do
      expect(described_class.looks_like_token?("sk-ant-oat01-abc123")).to be true
      expect(described_class.looks_like_token?("sk-ant-api03-xyz")).to be true
    end

    it "returns false for authorization codes" do
      expect(described_class.looks_like_token?("auth-code#state-value")).to be false
      expect(described_class.looks_like_token?("shortcode")).to be false
    end

    it "strips whitespace before checking" do
      expect(described_class.looks_like_token?("  sk-ant-oat01-abc  ")).to be true
    end

    it "returns false for blank input" do
      expect(described_class.looks_like_token?("")).to be false
      expect(described_class.looks_like_token?(nil)).to be false
    end
  end

  describe ".exchange" do
    let(:token_url) { described_class::TOKEN_URL }

    it "exchanges a code for the access token" do
      stub_request(:post, token_url)
        .with(body: hash_including("grant_type" => "authorization_code", "code" => "the-code", "code_verifier" => "ver"))
        .to_return(status: 200, body: { access_token: "sk-ant-oat01-xyz" }.to_json, headers: { "Content-Type" => "application/json" })

      token = described_class.exchange(code: "the-code", verifier: "ver", state: "st", redirect_uri: "http://x/cb")

      expect(token).to eq("sk-ant-oat01-xyz")
    end

    it "splits the paste-flow code#state form and posts only the code" do
      stub_request(:post, token_url)
        .with(body: hash_including("code" => "abc", "state" => "embedded"))
        .to_return(status: 200, body: { access_token: "tok" }.to_json, headers: { "Content-Type" => "application/json" })

      token = described_class.exchange(code: "abc#embedded", verifier: "ver", state: "session-state", redirect_uri: "http://x/cb")

      expect(token).to eq("tok")
    end

    it "raises a friendly error when the code is blank" do
      expect {
        described_class.exchange(code: "  ", verifier: "ver", state: "st", redirect_uri: "http://x/cb")
      }.to raise_error(described_class::Error, /Missing authorization code/)
    end

    it "raises with the provider error description on rejection" do
      stub_request(:post, token_url).to_return(
        status: 400,
        body: { error: "invalid_grant", error_description: "Code expired." }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

      expect {
        described_class.exchange(code: "x", verifier: "v", state: "s", redirect_uri: "http://x/cb")
      }.to raise_error(described_class::Error, "Code expired.")
    end

    it "raises when no access token comes back" do
      stub_request(:post, token_url).to_return(status: 200, body: {}.to_json, headers: { "Content-Type" => "application/json" })

      expect {
        described_class.exchange(code: "x", verifier: "v", state: "s", redirect_uri: "http://x/cb")
      }.to raise_error(described_class::Error, /did not return an access token/)
    end
  end
end
