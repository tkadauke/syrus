require "rails_helper"

RSpec.describe "Repository whiteboards", type: :request do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before { sign_in_as(user) }

  it "serves the SPA shell for the retired repository-wide whiteboard GET path instead of 404ing" do
    get "/repositories/#{repo.id}/whiteboard"

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
