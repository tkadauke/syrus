require "rails_helper"

RSpec.describe "API: /api/v1/app/auth", type: :request do
  def parse_body = JSON.parse(response.body)

  it "signs in incomplete first-run users and sends them to onboarding" do
    user = Factories.user(email_address: "operator@example.com", password: "supersecret")

    expect {
      post "/api/v1/app/auth/session", params: {
        email_address: "operator@example.com",
        password: "supersecret"
      }, as: :json
    }.to change { user.sessions.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["redirect_to"]).to eq(onboarding_path)
  end

  it "signs in completed users with the normal default route" do
    user = Factories.user(email_address: "operator@example.com", password: "supersecret")
    repository = Factories.repository(user: user)
    Factories.job_record(
      user: user,
      repository: repository,
      state: "closed",
      closure_reason: "pr_merged",
      finished_at: Time.current
    )

    post "/api/v1/app/auth/session", params: {
      email_address: "operator@example.com",
      password: "supersecret"
    }, as: :json

    expect(response).to have_http_status(:ok)
    expect(parse_body["redirect_to"]).to eq(root_path)
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

  it "exposes public auth state for first account setup without private data" do
    get "/api/v1/app/auth/status"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq(
      "authenticated" => false,
      "first_signup" => true,
      "signups_open" => false,
      "valid_invitation" => false,
      "cta" => {
        "kind" => "create_first_account",
        "label" => "Create first account",
        "href" => "/users/new"
      }
    )
  end

  it "exposes public auth state for open signups" do
    Factories.user
    AppSetting.current.update!(signups_open: true)

    get "/api/v1/app/auth/status"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "authenticated" => false,
      "first_signup" => false,
      "signups_open" => true,
      "valid_invitation" => false,
      "cta" => {
        "kind" => "sign_up",
        "label" => "Create account",
        "href" => "/users/new"
      }
    )
  end

  it "exposes public auth state for invite-only instances without user data" do
    user = Factories.user(email_address: "operator@example.com")
    Invitation.create!(invited_by: user, email_address: "guest@example.com")

    get "/api/v1/app/auth/status"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "authenticated" => false,
      "first_signup" => false,
      "signups_open" => false,
      "valid_invitation" => false,
      "cta" => {
        "kind" => "sign_in",
        "label" => "Sign in",
        "href" => "/session/new"
      }
    )
    expect(response.body).not_to include("operator@example.com")
    expect(response.body).not_to include("guest@example.com")
  end

  it "exposes public auth state for valid invitation links without invitation metadata" do
    admin = Factories.user(email_address: "operator@example.com")
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    get "/api/v1/app/auth/status", params: { token: invitation.token }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "authenticated" => false,
      "first_signup" => false,
      "signups_open" => false,
      "valid_invitation" => true,
      "cta" => {
        "kind" => "accept_invitation",
        "label" => "Accept invitation",
        "href" => "/users/new?token=#{invitation.token}"
      }
    )
    expect(response.body).not_to include("operator@example.com")
    expect(response.body).not_to include("guest@example.com")
  end

  it "exposes authenticated public auth state without user metadata" do
    user = Factories.user(email_address: "operator@example.com")
    sign_in_as(user)

    get "/api/v1/app/auth/status"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "authenticated" => true,
      "cta" => {
        "kind" => "dashboard",
        "label" => "Open dashboard",
        "href" => "/dashboard/jobs?view=list"
      }
    )
    expect(response.body).not_to include("operator@example.com")
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
    expect(User.last).to be_admin
    expect(User.last.sessions.count).to eq(1)
    expect(parse_body["redirect_to"]).to eq(onboarding_path)
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
    expect(parse_body["redirect_to"]).to eq(onboarding_path)
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
