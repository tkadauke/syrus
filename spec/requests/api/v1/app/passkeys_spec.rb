require "rails_helper"

RSpec.describe "API: /api/v1/app/passkeys", type: :request do
  let(:user) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  describe "GET /api/v1/app/passkeys/registration_options" do
    it "returns 401 when not authenticated" do
      get "/api/v1/app/passkeys/registration_options"

      expect(response).to have_http_status(:unauthorized)
      expect(parse_body.dig("error", "code")).to eq("unauthorized")
    end

    it "returns 200 with challenge and user keys when authenticated" do
      sign_in_as(user)

      get "/api/v1/app/passkeys/registration_options"

      expect(response).to have_http_status(:ok)
      body = parse_body
      expect(body).to have_key("challenge")
      expect(body).to have_key("user")
      expect(body["user"]["id"]).to eq(user.webauthn_id)
    end

    it "creates a PasskeyChallenge record for the user" do
      sign_in_as(user)

      expect {
        get "/api/v1/app/passkeys/registration_options"
      }.to change { PasskeyChallenge.for_type("registration").where(user: user).count }.by(1)
    end

    it "sets challenge expiry to approximately 5 minutes from now" do
      sign_in_as(user)

      get "/api/v1/app/passkeys/registration_options"

      challenge = PasskeyChallenge.for_type("registration").find_by!(user: user)
      expect(challenge.expires_at).to be_within(10.seconds).of(5.minutes.from_now)
    end
  end

  describe "POST /api/v1/app/passkeys/register" do
    let(:external_id) { "cred-id-#{SecureRandom.hex(8)}" }
    let(:public_key) { "fake-public-key-#{SecureRandom.hex(8)}" }
    let(:challenge_value) { SecureRandom.urlsafe_base64(32) }

    let(:pending_challenge) do
      PasskeyChallenge.create_for!(
        type: "registration",
        challenge: challenge_value,
        user: user
      )
    end

    let(:mock_credential) do
      instance_double(
        WebAuthn::PublicKeyCredentialWithAttestation,
        id: external_id,
        public_key: public_key,
        sign_count: 0,
        verify: true
      )
    end

    before do
      allow(WebAuthn::Credential).to receive(:from_create).and_return(mock_credential)
    end

    it "returns 401 when not authenticated" do
      post "/api/v1/app/passkeys/register", params: { credential: { id: external_id } }

      expect(response).to have_http_status(:unauthorized)
    end

    context "when authenticated" do
      before do
        sign_in_as(user)
        pending_challenge
      end

      it "returns 201 and creates a Passkey with a valid credential" do
        expect {
          post "/api/v1/app/passkeys/register",
               params: { credential: { id: external_id, type: "public-key" }, nickname: "My Passkey" }
        }.to change { user.passkeys.count }.by(1)

        expect(response).to have_http_status(:created)
        body = parse_body
        expect(body["id"]).to eq(user.passkeys.last.id)
        expect(body["nickname"]).to eq("My Passkey")
      end

      it "destroys the challenge after successful registration" do
        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" } }

        expect(PasskeyChallenge.find_by(id: pending_challenge.id)).to be_nil
      end

      it "stores the nickname when provided" do
        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" }, nickname: "  Work Mac  " }

        expect(user.passkeys.last.nickname).to eq("Work Mac")
      end

      it "stores nil nickname when not provided" do
        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" } }

        expect(user.passkeys.last.nickname).to be_nil
      end

      it "returns 422 when WebAuthn verification fails" do
        allow(mock_credential).to receive(:verify).and_raise(WebAuthn::Error, "Verification failed")

        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "code")).to eq("webauthn_error")
        expect(parse_body.dig("error", "message")).to eq("Verification failed")
      end

      it "does not create a Passkey when verification fails" do
        allow(mock_credential).to receive(:verify).and_raise(WebAuthn::Error, "Verification failed")

        expect {
          post "/api/v1/app/passkeys/register",
               params: { credential: { id: external_id, type: "public-key" } }
        }.not_to change { user.passkeys.count }
      end
    end

    context "when there is no pending challenge" do
      before { sign_in_as(user) }

      it "returns 422 with no_challenge error" do
        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "code")).to eq("no_challenge")
      end
    end

    context "when the challenge has expired" do
      before do
        sign_in_as(user)
        PasskeyChallenge.create!(
          challenge_type: "registration",
          challenge: challenge_value,
          user: user,
          expires_at: 1.minute.ago
        )
      end

      it "returns 422 because expired challenges are excluded from valid scope" do
        post "/api/v1/app/passkeys/register",
             params: { credential: { id: external_id, type: "public-key" } }

        expect(response).to have_http_status(:unprocessable_content)
        expect(parse_body.dig("error", "code")).to eq("no_challenge")
      end
    end
  end

  describe "GET /api/v1/app/passkeys/authentication_options" do
    it "returns 200 with a challenge" do
      get "/api/v1/app/passkeys/authentication_options"

      expect(response).to have_http_status(:ok)
      expect(parse_body).to have_key("challenge")
    end

    it "does not require authentication" do
      get "/api/v1/app/passkeys/authentication_options"

      expect(response).not_to have_http_status(:unauthorized)
    end

    it "creates a PasskeyChallenge with no user" do
      expect {
        get "/api/v1/app/passkeys/authentication_options"
      }.to change { PasskeyChallenge.for_type("authentication").count }.by(1)

      challenge = PasskeyChallenge.for_type("authentication").last
      expect(challenge.user).to be_nil
    end

    it "sets challenge expiry to approximately 5 minutes from now" do
      get "/api/v1/app/passkeys/authentication_options"

      challenge = PasskeyChallenge.for_type("authentication").last
      expect(challenge.expires_at).to be_within(10.seconds).of(5.minutes.from_now)
    end
  end

  describe "POST /api/v1/app/passkeys/authenticate" do
    let(:external_id) { "auth-cred-id-#{SecureRandom.hex(8)}" }
    let(:public_key) { "fake-public-key-#{SecureRandom.hex(8)}" }
    let(:challenge_value) { SecureRandom.urlsafe_base64(32) }

    let!(:passkey) do
      user.passkeys.create!(
        external_id: external_id,
        public_key: public_key,
        sign_count: 0
      )
    end

    let!(:pending_challenge) do
      PasskeyChallenge.create_for!(type: "authentication", challenge: challenge_value)
    end

    let(:mock_credential) do
      instance_double(
        WebAuthn::PublicKeyCredentialWithAssertion,
        id: external_id,
        sign_count: 1,
        verify: true
      )
    end

    before do
      allow(WebAuthn::Credential).to receive(:from_get).and_return(mock_credential)
    end

    it "returns 200, sets session cookie, and returns redirect_to" do
      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      expect(response).to have_http_status(:ok)
      expect(parse_body).to have_key("redirect_to")
      expect(cookies[:session_id]).to be_present
    end

    it "updates sign_count and last_used_at on the passkey" do
      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      passkey.reload
      expect(passkey.sign_count).to eq(1)
      expect(passkey.last_used_at).to be_within(5.seconds).of(Time.current)
    end

    it "destroys the challenge after successful authentication" do
      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      expect(PasskeyChallenge.find_by(id: pending_challenge.id)).to be_nil
    end

    it "returns 422 when WebAuthn verification fails" do
      allow(mock_credential).to receive(:verify).and_raise(WebAuthn::Error, "Signature mismatch")

      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("webauthn_error")
      expect(parse_body.dig("error", "message")).to eq("Signature mismatch")
    end

    it "returns 422 when the challenge has expired" do
      pending_challenge.update!(expires_at: 1.minute.ago)

      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_credential")
    end

    it "returns 422 (not 404) when the external_id is unknown" do
      allow(mock_credential).to receive(:id).and_return("unknown-external-id")

      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: "unknown-external-id", type: "public-key" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_credential")
    end

    it "returns 422 when the challenge has already been used/destroyed" do
      pending_challenge.destroy

      post "/api/v1/app/passkeys/authenticate",
           params: { challenge: challenge_value, credential: { id: external_id, type: "public-key" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_credential")
    end
  end
end
