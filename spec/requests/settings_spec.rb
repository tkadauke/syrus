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
        expect(response.body).to include("Leaving secret fields blank keeps the stored value unchanged")
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

      it "updates Telegram secrets when provided" do
        patch settings_path, params: {
          app_setting: {
            telegram_bot_token: "bot-token",
            telegram_webhook_secret: "webhook-secret"
          }
        }

        setting = AppSetting.current.reload
        expect(setting.telegram_bot_token).to eq("bot-token")
        expect(setting.telegram_webhook_secret).to eq("webhook-secret")
      end

      it "keeps Telegram secrets unchanged when update fields are blank" do
        setting = AppSetting.current
        setting.update!(telegram_bot_token: "bot-token", telegram_webhook_secret: "webhook-secret")

        patch settings_path, params: {
          app_setting: {
            signups_open: "1",
            telegram_bot_token: "",
            telegram_webhook_secret: ""
          }
        }

        setting.reload
        expect(setting.signups_open).to be(true)
        expect(setting.telegram_bot_token).to eq("bot-token")
        expect(setting.telegram_webhook_secret).to eq("webhook-secret")
      end

      it "clears each app-wide Telegram secret only through the explicit clear control" do
        setting = AppSetting.current
        setting.update!(telegram_bot_token: "bot-token", telegram_webhook_secret: "webhook-secret")

        AppSetting::CLEARABLE_SECRETS.each_key do |secret|
          patch settings_path, params: { clear_secret: secret }
          expect(response).to redirect_to(edit_settings_path)
          expect(flash[:notice]).to include("cleared")
          expect(setting.reload.public_send(secret)).to be_nil
        end
      end

      it "rejects unknown app secret names" do
        patch settings_path, params: { clear_secret: "github_app_id" }

        expect(response).to redirect_to(edit_settings_path)
        expect(flash[:alert]).to eq("Unknown secret.")
      end
    end
  end
end
