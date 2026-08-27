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


  describe "GET /api/v1/app/themes/:id" do
    it "returns a built-in theme" do
      ocean = theme(slug: "ocean", built_in: true, name: "Ocean")
      sign_in_as(Factories.user)

      get "/api/v1/app/themes/#{ocean.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body["theme"]).to eq(
        "id" => ocean.id,
        "slug" => "ocean",
        "name" => "Ocean",
        "built_in" => true,
        "tokens" => JSON.parse(ocean.tokens.to_json)
      )
    end

    it "returns the signed-in user's own custom theme" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, name: "Mine", owner_user: user)
      sign_in_as(user)

      get "/api/v1/app/themes/#{mine.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body["theme"]["slug"]).to eq("mine")
    end

    it "404s for another user's custom theme" do
      other = Factories.user
      theirs = theme(slug: "theirs", built_in: false, name: "Theirs", owner_user: other)
      sign_in_as(Factories.user)

      get "/api/v1/app/themes/#{theirs.id}"

      expect(response).to have_http_status(:not_found)
    end

    it "404s for a nonexistent theme id" do
      sign_in_as(Factories.user)

      get "/api/v1/app/themes/999999"

      expect(response).to have_http_status(:not_found)
    end

    it "requires authentication" do
      ocean = theme(slug: "ocean", built_in: true, name: "Ocean")

      get "/api/v1/app/themes/#{ocean.id}"

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
