require "rails_helper"

RSpec.describe "API: /api/v1/app/tours", type: :request do
  def parse_body = JSON.parse(response.body)

  describe "POST /api/v1/app/tours/dismiss" do
    it "requires authentication" do
      post "/api/v1/app/tours/dismiss", params: { tour_id: "dashboard" }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "marks a tour as seen and returns the updated seen_tours list" do
      user = Factories.user
      sign_in_as(user)

      post "/api/v1/app/tours/dismiss", params: { tour_id: "dashboard" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(parse_body["seen_tours"]).to eq([ "dashboard" ])
      expect(user.reload.seen_tours).to eq([ "dashboard" ])
    end

    it "accumulates multiple distinct tours without duplicating" do
      user = Factories.user
      sign_in_as(user)

      post "/api/v1/app/tours/dismiss", params: { tour_id: "dashboard" }, as: :json
      post "/api/v1/app/tours/dismiss", params: { tour_id: "job_detail" }, as: :json
      post "/api/v1/app/tours/dismiss", params: { tour_id: "dashboard" }, as: :json

      expect(response).to have_http_status(:ok)
      expect(user.reload.seen_tours).to contain_exactly("dashboard", "job_detail")
    end

    it "returns validation error when tour_id is missing" do
      user = Factories.user
      sign_in_as(user)

      post "/api/v1/app/tours/dismiss", params: {}, as: :json

      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "DELETE /api/v1/app/tours/reset" do
    it "requires authentication" do
      delete "/api/v1/app/tours/reset"

      expect(response).to have_http_status(:unauthorized)
    end

    it "clears all seen tours and returns an empty list" do
      user = Factories.user
      user.mark_tour_seen("dashboard")
      user.mark_tour_seen("chat")
      sign_in_as(user)

      delete "/api/v1/app/tours/reset"

      expect(response).to have_http_status(:ok)
      expect(parse_body["seen_tours"]).to eq([])
      expect(user.reload.seen_tours).to eq([])
    end

    it "is idempotent when seen_tours is already empty" do
      user = Factories.user
      sign_in_as(user)

      delete "/api/v1/app/tours/reset"

      expect(response).to have_http_status(:ok)
      expect(parse_body["seen_tours"]).to eq([])
    end
  end
end
