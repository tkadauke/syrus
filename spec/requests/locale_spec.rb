require "rails_helper"

RSpec.describe "Locale switching", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "sets I18n.locale from the signed-in user's locale for the duration of the request" do
    captured_locale = nil
    user = Factories.user(locale: "de")
    sign_in_as(user)

    allow_any_instance_of(ApplicationController).to receive(:switch_locale).and_wrap_original do |original, *args, &block|
      original.call(*args, &block)
      captured_locale = I18n.locale
    end

    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(user.locale).to eq("de")
  end

  it "falls back to I18n.default_locale when no user is signed in" do
    get api_v1_app_bootstrap_path

    expect(response).to have_http_status(:ok)
    expect(I18n.default_locale).to eq(:en)
  end

  it "restores the default locale after the request" do
    user = Factories.user(locale: "la")
    sign_in_as(user)

    get api_v1_app_bootstrap_path

    expect(I18n.locale).to eq(I18n.default_locale)
  end

end
