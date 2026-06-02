require "rails_helper"

RSpec.describe "API: /api/v1/app/auth", type: :request do
  def parse_body = JSON.parse(response.body)

  it "signs in with valid credentials" do
    user = Factories.user(email_address: "operator@example.com", password: "supersecret")

    expect {
      post "/api/v1/app/auth/session", params: {
        email_address: "operator@example.com",
        password: "supersecret"
      }, as: :json
    }.to change { user.sessions.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["redirect_to"]).to be_present
  end

  it "rejects invalid sign-in credentials as JSON" do
    Factories.user(email_address: "operator@example.com", password: "supersecret")

    post "/api/v1/app/auth/session", params: {
      email_address: "operator@example.com",
      password: "wrong"
    }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("invalid_credentials")
  end

  it "describes open sign-up state" do
    get "/api/v1/app/auth/signup"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "allowed" => true,
      "first_signup" => true,
      "invitation" => nil
    )
  end

  it "creates the first user through JSON sign-up" do
    expect {
      post "/api/v1/app/auth/users", params: {
        user: {
          email_address: "new@example.com",
          password: "supersecret",
          password_confirmation: "supersecret"
        }
      }, as: :json
    }.to change(User, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(parse_body["redirect_to"]).to eq(setup_path)
    expect(User.last).to be_admin
    expect(User.last.sessions.count).to eq(1)
  end

  it "creates an invited user through JSON sign-up" do
    admin = Factories.user
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    expect {
      post "/api/v1/app/auth/users", params: {
        user: {
          email_address: "guest@example.com",
          password: "supersecret",
          password_confirmation: "supersecret",
          invitation_token: invitation.token
        }
      }, as: :json
    }.to change(User, :count).by(1)

    expect(response).to have_http_status(:created)
    expect(parse_body["redirect_to"]).to eq(setup_path)
    expect(invitation.reload).to be_accepted
  end

  it "blocks closed sign-up without an invitation" do
    Factories.user

    post "/api/v1/app/auth/users", params: {
      user: {
        email_address: "blocked@example.com",
        password: "supersecret",
        password_confirmation: "supersecret"
      }
    }, as: :json

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("signup_closed")
  end

  it "sends password reset instructions without exposing account existence" do
    Factories.user(email_address: "operator@example.com")

    expect {
      post "/api/v1/app/auth/passwords", params: {
        email_address: "operator@example.com"
      }, as: :json
    }.to have_enqueued_mail(PasswordsMailer, :reset)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to match(/Password reset instructions/)
  end

  it "updates a password with a valid reset token" do
    user = Factories.user(password: "oldsecret")
    token = user.password_reset_token

    patch "/api/v1/app/auth/passwords/#{token}", params: {
      password: "newsecret",
      password_confirmation: "newsecret"
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(User.authenticate_by(email_address: user.email_address, password: "newsecret")).to eq(user)
  end
end
