require "rails_helper"

RSpec.describe "API: /api/v1/app/sidebar_nav_order", type: :request do
  def parse_body = JSON.parse(response.body)

  it "persists the signed-in user's chosen nav order" do
    user = Factories.user
    sign_in_as(user)

    patch "/api/v1/app/sidebar_nav_order", params: { order: %w[ repositories dashboard terminal ] }, as: :json

    expect(response).to have_http_status(:ok)
    expect(parse_body["sidebar_nav_order"]).to eq(%w[ repositories dashboard terminal ])
    expect(user.reload.sidebar_nav_order).to eq(%w[ repositories dashboard terminal ])
  end

  it "overwrites a previously saved order" do
    user = Factories.user
    user.update_sidebar_nav_order!(%w[ dashboard repositories ])
    sign_in_as(user)

    patch "/api/v1/app/sidebar_nav_order", params: { order: %w[ terminal dashboard ] }, as: :json

    expect(response).to have_http_status(:ok)
    expect(user.reload.sidebar_nav_order).to eq(%w[ terminal dashboard ])
  end

  it "treats a missing order as clearing the saved order" do
    user = Factories.user
    user.update_sidebar_nav_order!(%w[ dashboard repositories ])
    sign_in_as(user)

    patch "/api/v1/app/sidebar_nav_order", params: {}, as: :json

    expect(response).to have_http_status(:ok)
    expect(parse_body["sidebar_nav_order"]).to eq([])
    expect(user.reload.sidebar_nav_order).to eq([])
  end

  it "requires authentication" do
    Factories.user

    patch "/api/v1/app/sidebar_nav_order", params: { order: %w[ dashboard ] }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
