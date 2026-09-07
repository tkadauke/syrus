require "rails_helper"

RSpec.describe "Filter FK options", type: :request do
  describe "GET /filters/fk_options" do
    it "serves the SPA shell for the retired legacy JSON helper path instead of 404ing" do
      user = Factories.user
      sign_in_as(user)

      get "/filters/fk_options"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="syrus-spa-root"')
    end
  end
end
