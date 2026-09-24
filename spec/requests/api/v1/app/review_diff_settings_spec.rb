require "rails_helper"

RSpec.describe "API: /api/v1/app/review_diff_settings", type: :request do
  let(:user) { Factories.user(ui_preferences: { "review_diff_settings" => { "line_wrapping" => "scroll", "line_numbers" => false } }) }

  def parse_body
    JSON.parse(response.body)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/review_diff_settings"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "returns stored settings merged with defaults" do
    sign_in_as(user)

    get "/api/v1/app/review_diff_settings"

    expect(response).to have_http_status(:ok)
    expect(parse_body["review_diff_settings"]).to include(
      "line_wrapping" => "scroll",
      "desktop_view" => "unified",
      "syntax_highlighting" => true,
      "line_numbers" => false,
      "file_list" => true
    )
  end

  it "updates partial settings without replacing existing settings" do
    sign_in_as(user)

    patch "/api/v1/app/review_diff_settings", params: {
      review_diff_settings: {
        desktop_view: "split",
        tab_width: 4,
        syntax_highlighting: false
      }
    }

    expect(response).to have_http_status(:ok)
    expect(parse_body["message"]).to eq("Review settings updated.")
    expect(parse_body["review_diff_settings"]).to include(
      "line_wrapping" => "scroll",
      "desktop_view" => "split",
      "tab_width" => 4,
      "syntax_highlighting" => false,
      "line_numbers" => false
    )
    expect(user.reload.review_diff_settings).to include("desktop_view" => "split", "line_numbers" => false)
  end

  it "normalizes unknown or invalid values back to defaults" do
    sign_in_as(user)

    patch "/api/v1/app/review_diff_settings", params: {
      review_diff_settings: {
        desktop_view: "sideways",
        tab_width: 99,
        file_list: "0"
      }
    }

    expect(response).to have_http_status(:ok)
    expect(parse_body["review_diff_settings"]).to include(
      "desktop_view" => "unified",
      "tab_width" => 2,
      "file_list" => false
    )
  end
end
