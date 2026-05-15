require "rails_helper"

RSpec.describe "Settings", type: :request do
  let(:admin) { Factories.user }
  let(:non_admin) { Factories.user }

  describe "GET /settings" do
    it "requires authentication" do
      admin  # force a User to exist; first-run setup redirects to new_user instead
      get settings_path
      expect(response).to redirect_to(new_session_path)
    end

    context "as a non-admin" do
      before { admin; sign_in_as(non_admin) }

      it "serves the credentials page as an intentional alias" do
        get settings_path
        expect(response).to be_successful
        expect(response.body).to include("My credentials")
      end

      it "shows only My credentials in the in-page nav" do
        get settings_path
        expect(response.body).to include("My credentials")
        expect(response.body).not_to include("Invitations")
        expect(response.body).not_to include("App settings")
      end
    end

    context "as an admin" do
      before { sign_in_as(admin) }

      it "serves the credentials page as an intentional alias" do
        get settings_path
        expect(response).to be_successful
        expect(response.body).to include("My credentials")
      end

      it "shows only the per-user sections in the in-page nav (Invitations + App settings are admin-area-only)" do
        get settings_path
        expect(response.body).to include("My credentials")
        expect(response.body).to include("Templates")
        expect(response.body).not_to match(/<a[^>]*>Invitations/)  # moved to admin area
        expect(response.body).not_to match(/<a[^>]*>App settings/) # moved to admin area
      end
    end
  end

  describe "GET /settings/edit" do
    it "requires authentication" do
      admin  # force a User to exist; first-run setup redirects to new_user instead
      get edit_settings_path
      expect(response).to redirect_to(new_session_path)
    end

    context "as a non-admin" do
      before { admin; sign_in_as(non_admin) }

      it "blocks edit" do
        get edit_settings_path
        expect(response).to redirect_to(root_path)
      end

      it "blocks update" do
        expect {
          patch settings_path, params: { app_setting: { signups_open: "1" } }
        }.not_to change { AppSetting.signups_open? }
      end
    end

    context "as an admin" do
      before { sign_in_as(admin) }

      it "renders the toggle" do
        get edit_settings_path
        expect(response).to be_successful
        expect(response.body).to include("Open signups")
      end

      it "flips signups_open on" do
        patch settings_path, params: { app_setting: { signups_open: "1" } }
        expect(AppSetting.signups_open?).to be true
      end

      it "flips signups_open off" do
        AppSetting.current.update!(signups_open: true)
        patch settings_path, params: { app_setting: { signups_open: "0" } }
        expect(AppSetting.signups_open?).to be false
      end
    end
  end
end
