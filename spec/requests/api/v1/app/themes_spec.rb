require "rails_helper"

RSpec.describe "API: /api/v1/app/themes", type: :request do
  def parse_body
    JSON.parse(response.body)
  end

  def legible_tokens
    {
      "light" => {
        "brand" => "#b6492e", "brand-emphasis" => "#973b25", "surface" => "#ffffff",
        "surface-raised" => "#f9fafb", "border" => "#e5e7eb", "text-primary" => "#111827",
        "text-secondary" => "#6b7280", "success" => "#047857", "warning" => "#b45309",
        "danger" => "#b91c1c", "info" => "#1d4ed8", "neutral" => "#374151", "on-brand" => "#ffffff"
      },
      "dark" => {
        "brand" => "#b6492e", "brand-emphasis" => "#dba28b", "surface" => "#111827",
        "surface-raised" => "#1f2937", "border" => "#374151", "text-primary" => "#f3f4f6",
        "text-secondary" => "#9ca3af", "success" => "#a7f3d0", "warning" => "#fde68a",
        "danger" => "#fecaca", "info" => "#bfdbfe", "neutral" => "#e5e7eb", "on-brand" => "#ffffff"
      }
    }
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
      "position" => nil,
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
        "position" => nil,
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

  describe "POST /api/v1/app/themes" do
    it "creates an owned custom theme at the next position" do
      user = Factories.user
      theme(owner_user: user, built_in: false, position: 0, tokens: legible_tokens)
      sign_in_as(user)

      post "/api/v1/app/themes", params: {
        theme: {
          name: "Copper Night",
          tokens: legible_tokens
        }
      }

      expect(response).to have_http_status(:created)
      created = Theme.find(parse_body.dig("theme", "id"))
      expect(created).to have_attributes(
        name: "Copper Night",
        slug: "copper-night-#{user.id}",
        owner_user_id: user.id,
        built_in: false,
        position: 1
      )
      expect(created.tokens).to eq(legible_tokens)
    end

    it "rejects a theme that fails the shared contrast check" do
      user = Factories.user
      tokens = legible_tokens.deep_dup
      tokens["light"]["text-primary"] = "#ffffff"
      sign_in_as(user)

      post "/api/v1/app/themes", params: { theme: { name: "Washed Out", tokens: tokens } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("contrast_check_failed")
      expect(parse_body.dig("error", "issues").first).to include(
        "mode" => "light",
        "foreground" => "text-primary",
        "background" => "surface",
        "required_ratio" => 4.5
      )
      expect(Theme.where(name: "Washed Out")).not_to exist
    end
  end

  describe "PATCH /api/v1/app/themes/:id" do
    it "renames a custom theme and merges token overrides" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, name: "Old Name", owner_user: user, tokens: legible_tokens)
      sign_in_as(user)

      patch "/api/v1/app/themes/#{mine.id}", params: {
        theme: {
          name: "New Name",
          tokens: {
            light: {
              brand: "#0f766e",
              "on-brand": "#ffffff"
            }
          }
        }
      }

      expect(response).to have_http_status(:ok)
      expect(mine.reload.name).to eq("New Name")
      expect(mine.tokens["light"]["brand"]).to eq("#0f766e")
      expect(mine.tokens["light"]["surface"]).to eq(legible_tokens["light"]["surface"])
      expect(mine.tokens["dark"]).to eq(legible_tokens["dark"])
      expect(parse_body.dig("theme", "name")).to eq("New Name")
    end

    it "rejects token edits that fail the shared contrast check" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, name: "Mine", owner_user: user, tokens: legible_tokens)
      sign_in_as(user)

      patch "/api/v1/app/themes/#{mine.id}", params: {
        theme: {
          tokens: {
            dark: { "on-brand": "#b6492e" }
          }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("contrast_check_failed")
      expect(parse_body.dig("error", "message")).to include("on-brand").and include("brand").and include("4.5")
      expect(mine.reload.tokens["dark"]["on-brand"]).to eq("#ffffff")
    end

    it "404s when updating another user's custom theme" do
      theirs = theme(slug: "theirs", built_in: false, owner_user: Factories.user, tokens: legible_tokens)
      sign_in_as(Factories.user)

      patch "/api/v1/app/themes/#{theirs.id}", params: { theme: { name: "Stolen" } }

      expect(response).to have_http_status(:not_found)
      expect(theirs.reload.name).not_to eq("Stolen")
    end

    it "404s when updating a built-in theme" do
      built_in = theme(slug: "terracotta", built_in: true, owner_user: nil, tokens: legible_tokens)
      sign_in_as(Factories.user)

      patch "/api/v1/app/themes/#{built_in.id}", params: { theme: { name: "Renamed" } }

      expect(response).to have_http_status(:not_found)
      expect(built_in.reload.name).not_to eq("Renamed")
    end
  end

  describe "DELETE /api/v1/app/themes/:id" do
    it "deletes an owned custom theme" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, owner_user: user, tokens: legible_tokens)
      sign_in_as(user)

      delete "/api/v1/app/themes/#{mine.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body["deleted_theme_id"]).to eq(mine.id)
      expect(Theme.where(id: mine.id)).not_to exist
    end

    it "falls back to Terracotta when deleting the active custom theme" do
      terracotta = theme(slug: "terracotta", built_in: true, owner_user: nil, tokens: legible_tokens)
      mine = theme(slug: "mine", built_in: false, owner_user: nil, tokens: legible_tokens)
      user = Factories.user(color_theme: mine)
      mine.update!(owner_user: user)
      sign_in_as(user)

      delete "/api/v1/app/themes/#{mine.id}"

      expect(response).to have_http_status(:ok)
      expect(parse_body["fallback_theme_id"]).to eq(terracotta.id)
      expect(user.reload.color_theme_id).to eq(terracotta.id)
      expect(Theme.where(id: mine.id)).not_to exist
    end

    it "404s when deleting another user's custom theme or a built-in theme" do
      user = Factories.user
      theirs = theme(slug: "theirs", built_in: false, owner_user: Factories.user, tokens: legible_tokens)
      built_in = theme(slug: "terracotta", built_in: true, owner_user: nil, tokens: legible_tokens)
      sign_in_as(user)

      delete "/api/v1/app/themes/#{theirs.id}"
      expect(response).to have_http_status(:not_found)
      expect(Theme.where(id: theirs.id)).to exist

      delete "/api/v1/app/themes/#{built_in.id}"
      expect(response).to have_http_status(:not_found)
      expect(Theme.where(id: built_in.id)).to exist
    end
  end

  describe "PATCH /api/v1/app/themes/reorder" do
    it "persists custom theme order for the signed-in user" do
      user = Factories.user
      first = theme(slug: "first", built_in: false, owner_user: user, position: 0, tokens: legible_tokens)
      second = theme(slug: "second", built_in: false, owner_user: user, position: 1, tokens: legible_tokens)
      third = theme(slug: "third", built_in: false, owner_user: user, position: 2, tokens: legible_tokens)
      sign_in_as(user)

      patch "/api/v1/app/themes/reorder", params: { ids: [ third.id, first.id, second.id ] }

      expect(response).to have_http_status(:ok)
      expect(third.reload.position).to eq(0)
      expect(first.reload.position).to eq(1)
      expect(second.reload.position).to eq(2)
      expect(parse_body["themes"].map { |theme| theme["id"] }).to eq([ third.id, first.id, second.id ])
    end

    it "404s when reorder includes another user's theme or a built-in theme" do
      user = Factories.user
      mine = theme(slug: "mine", built_in: false, owner_user: user, position: 0, tokens: legible_tokens)
      theirs = theme(slug: "theirs", built_in: false, owner_user: Factories.user, position: 0, tokens: legible_tokens)
      built_in = theme(slug: "terracotta", built_in: true, owner_user: nil, tokens: legible_tokens)
      sign_in_as(user)

      patch "/api/v1/app/themes/reorder", params: { ids: [ theirs.id, mine.id ] }
      expect(response).to have_http_status(:not_found)
      expect(mine.reload.position).to eq(0)

      patch "/api/v1/app/themes/reorder", params: { ids: [ built_in.id, mine.id ] }
      expect(response).to have_http_status(:not_found)
      expect(mine.reload.position).to eq(0)
    end
  end
end
