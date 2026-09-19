require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/invitations", type: :request do
  let!(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  def parse_body
    JSON.parse(response.body)
  end

  def capture_sql
    queries = []
    callback = ->(_name, _started, _finished, _id, payload) do
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]

      queries << payload[:sql].to_s
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/invitations"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/invitations"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "lists pending invitations with one-time signup URLs" do
    sign_in_as(admin)
    pending = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    Invitation.create!(
      invited_by: admin,
      email_address: "expired@example.com",
      expires_at: 1.hour.ago
    )

    get "/api/v1/app/admin/invitations"

    expect(response).to have_http_status(:ok)
    invitations = parse_body["invitations"]
    expect(invitations.size).to eq(1)
    expect(invitations.first).to include(
      "id" => pending.id,
      "email_address" => "guest@example.com",
      "token" => pending.token,
      "share_url" => "http://www.example.com/users/new?token=#{pending.token}",
      "invited_by_email_address" => admin.email_address
    )
  end

  it "preloads inviters when listing pending invitations" do
    sign_in_as(admin)
    inviters = Array.new(4) { |index| Factories.user(email_address: "inviter-#{index}@example.com") }
    inviters.each_with_index do |inviter, index|
      Invitation.create!(invited_by: inviter, email_address: "guest-#{index}@example.com")
    end

    queries = capture_sql do
      get "/api/v1/app/admin/invitations"
    end

    expect(response).to have_http_status(:ok)
    expect(parse_body["invitations"].size).to eq(4)
    user_selects = queries.grep(/\ASELECT .* FROM "?users"?/i)
    expect(user_selects.size).to be <= 2
  end

  it "creates invitations tied to the current admin" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/invitations", params: { invitation: { email_address: "Guest@Example.com " } }
    }.to change(Invitation, :count).by(1)
      .and have_enqueued_mail(InvitationMailer, :invite)

    expect(response).to have_http_status(:created)
    invitation = Invitation.last
    expect(invitation.invited_by).to eq(admin)
    expect(invitation.email_address).to eq("guest@example.com")
    expect(parse_body["message"]).to eq("Invitation created for guest@example.com.")
    expect(parse_body["invitations"].first).to include("id" => invitation.id)
  end

  it "returns a JSON validation error for invalid invitations" do
    sign_in_as(admin)

    expect {
      post "/api/v1/app/admin/invitations", params: { invitation: { email_address: "not-an-email" } }
    }.not_to change(Invitation, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(parse_body.dig("error", "message")).to include("Email address")
  end

  it "revokes invitations" do
    sign_in_as(admin)
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    expect {
      delete "/api/v1/app/admin/invitations/#{invitation.id}"
    }.to change(Invitation, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Invitation revoked.")
    expect(parse_body["invitations"]).to eq([])
  end
end
