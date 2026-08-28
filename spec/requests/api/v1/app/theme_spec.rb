require "rails_helper"

RSpec.describe "API: /api/v1/app/theme", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "updates the signed-in user's theme" do
    user = Factories.user(theme: "light")
    sign_in_as(user)

    patch "/api/v1/app/theme", params: { theme: "dark" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["theme"]).to eq("dark")
    expect(user.reload.theme).to eq("dark")
  end

  it "accepts system" do
    user = Factories.user(theme: "light")
    sign_in_as(user)

    patch "/api/v1/app/theme", params: { theme: "system" }

    expect(response).to have_http_status(:ok)
    expect(parse_body["theme"]).to eq("system")
    expect(user.reload.theme).to eq("system")
  end

  it "rejects unknown themes" do
    user = Factories.user(theme: "light")
    sign_in_as(user)

    patch "/api/v1/app/theme", params: { theme: "solarized" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(user.reload.theme).to eq("light")
  end

  it "requires authentication" do
    Factories.user

    patch "/api/v1/app/theme", params: { theme: "dark" }

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  describe "color_theme_id" do
    it "updates the signed-in user's color theme to a built-in theme" do
      ocean = theme(slug: "ocean", built_in: true)
      user = Factories.user
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: ocean.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["color_theme_id"]).to eq(ocean.id)
      expect(parse_body["color_theme"]).to eq(
        "id" => ocean.id,
        "slug" => "ocean",
        "name" => ocean.name,
        "built_in" => true,
        "tokens" => JSON.parse(ocean.tokens.to_json)
      )
      expect(user.reload.color_theme_id).to eq(ocean.id)
    end

    it "updates the signed-in user's color theme to their own custom theme" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, owner_user: user)
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: mine.id }

      expect(response).to have_http_status(:ok)
      expect(user.reload.color_theme_id).to eq(mine.id)
    end

    it "rejects another user's custom theme" do
      user = Factories.user
      other = Factories.user
      theirs = theme(slug: "theirs", built_in: false, owner_user: other)
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: theirs.id }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
      expect(user.reload.color_theme_id).to be_nil
    end

    it "rejects an unknown color theme id" do
      user = Factories.user
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: -1 }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("validation_failed")
    end

    it "clears the color theme when given a blank value" do
      ocean = theme(slug: "ocean", built_in: true)
      user = Factories.user(color_theme: ocean)
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: "" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["color_theme_id"]).to be_nil
      expect(user.reload.color_theme_id).to be_nil
    end

    it "leaves the mode untouched when only color_theme_id is given" do
      ocean = theme(slug: "ocean", built_in: true)
      user = Factories.user(theme: "dark")
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: ocean.id }

      expect(response).to have_http_status(:ok)
      expect(parse_body["theme"]).to eq("dark")
      expect(user.reload.theme).to eq("dark")
    end

    it "succeeds for a genuine JSON request body with only color_theme_id (regression: ParamsWrapper injecting an empty theme param)" do
      # Unlike the other examples in this file, a bare `params:` hash sends
      # form-encoded params, which never exercises ActionController::ParamsWrapper's
      # JSON-only wrapping. The real frontend client (patchJson) sends an actual
      # `application/json` body, which is what triggered this bug in practice.
      ocean = theme(slug: "ocean", built_in: true)
      user = Factories.user(theme: "dark")
      sign_in_as(user)

      patch "/api/v1/app/theme", params: { color_theme_id: ocean.id }.to_json, headers: { "CONTENT_TYPE" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["theme"]).to eq("dark")
      expect(user.reload.color_theme_id).to eq(ocean.id)
    end
  end
end
