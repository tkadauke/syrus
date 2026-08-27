require "rails_helper"

RSpec.describe "API: /api/v1/app/themes", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  it "lists built-in themes plus the signed-in user's own custom themes" do
    theme(slug: "ocean", built_in: true, name: "Ocean")
    theme(slug: "forest", built_in: true, name: "Forest")
    user = Factories.user
    mine = theme(slug: "mine", built_in: false, name: "Mine", owner_user: user)
    other = Factories.user
    theme(slug: "theirs", built_in: false, name: "Theirs", owner_user: other)
    sign_in_as(user)

    get "/api/v1/app/themes"

    expect(response).to have_http_status(:ok)
    slugs = parse_body["themes"].map { |t| t["slug"] }
    expect(slugs).to contain_exactly("ocean", "forest", "mine")

    mine_json = parse_body["themes"].find { |t| t["slug"] == "mine" }
    expect(mine_json).to eq(
      "id" => mine.id,
      "slug" => "mine",
      "name" => "Mine",
      "built_in" => false,
      "tokens" => JSON.parse(mine.tokens.to_json)
    )
  end

  it "requires authentication" do
    get "/api/v1/app/themes"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end
end
