require "rails_helper"

RSpec.describe "User signin", type: :request do
  it "redirects incomplete first-run users to onboarding" do
    user = Factories.user(email_address: "operator@example.com", password: "supersecret")

    post session_path, params: {
      email_address: "operator@example.com",
      password: "supersecret"
    }

    expect(response).to redirect_to(onboarding_url)
    expect(user.sessions.count).to eq(1)
  end

  it "keeps completed users on the normal default route" do
    user = Factories.user(email_address: "operator@example.com", password: "supersecret")
    repository = Factories.repository(user: user)
    Factories.job_record(
      user: user,
      repository: repository,
      state: "closed",
      closure_reason: "pr_merged",
      finished_at: Time.current
    )

    post session_path, params: {
      email_address: "operator@example.com",
      password: "supersecret"
    }

    expect(response).to redirect_to(root_url)
  end
end
