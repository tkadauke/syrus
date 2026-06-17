require "rails_helper"

RSpec.describe "User signup", type: :request do
  let(:valid_attrs) do
    { email_address: "new@example.com", password: "supersecret", password_confirmation: "supersecret" }
  end

  describe "first signup (no users yet)" do
    it "is always allowed, promotes the new user to admin, and sends them to setup" do
      expect {
        post users_path, params: { user: valid_attrs }
      }.to change(User, :count).by(1)

      expect(response).to redirect_to(onboarding_url)
      user = User.last
      expect(user.email_address).to eq("new@example.com")
      expect(user.admin?).to be true
    end

    it "renders the signup form" do
      get new_user_path
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end

  describe "with signups closed and no invitation" do
    before { Factories.user }  # ensures we're past the first-signup branch

    it "blocks GET /users/new and redirects to login" do
      get new_user_path
      expect(response).to redirect_to(new_session_path)
      expect(flash[:alert]).to match(/invitation-only/)
    end

    it "blocks POST /users and does not create a user" do
      expect {
        post users_path, params: { user: valid_attrs }
      }.not_to change(User, :count)
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "with signups open" do
    before do
      Factories.user
      AppSetting.current.update!(signups_open: true)
    end

    it "allows GET /users/new" do
      get new_user_path
      expect(response).to be_successful
    end

    it "creates a user (non-admin) on POST" do
      expect {
        post users_path, params: { user: valid_attrs }
      }.to change(User, :count).by(1)
      expect(User.last.admin?).to be false
    end
  end

  describe "SPA layout theme class" do
    it "renders the dark class before JavaScript for dark-theme users" do
      user = Factories.user(theme: "dark")
      sign_in_as(user)

      get dashboard_path

      expect(response).to be_successful
      expect(response.body).to include('<html class="dark">')
    end

    it "renders an empty html class for light-theme users" do
      user = Factories.user(theme: "light")
      sign_in_as(user)

      get dashboard_path

      expect(response).to be_successful
      expect(response.body).to include('<html class="">')
    end
  end

  describe "via valid invitation" do
    let(:admin) { Factories.user }
    let!(:invitation) { Invitation.create!(invited_by: admin, email_address: "guest@example.com") }

    it "allows GET /users/new?token=...even when signups are closed" do
      get new_user_path(token: invitation.token)
      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "creates the user and marks the invitation accepted on POST" do
      expect {
        post users_path, params: { user: valid_attrs.merge(invitation_token: invitation.token) }
      }.to change(User, :count).by(1)
      expect(invitation.reload).to be_accepted
    end
  end

  describe "via expired or accepted invitation" do
    let(:admin) { Factories.user }

    it "is rejected when the invitation is expired" do
      expired = Invitation.create!(invited_by: admin, email_address: "x@example.com", expires_at: 1.minute.ago)
      get new_user_path(token: expired.token)
      expect(response).to redirect_to(new_session_path)
    end

    it "is rejected when the invitation has already been accepted" do
      accepted = Invitation.create!(invited_by: admin, email_address: "x@example.com")
      accepted.accept!
      get new_user_path(token: accepted.token)
      expect(response).to redirect_to(new_session_path)
    end
  end
end
