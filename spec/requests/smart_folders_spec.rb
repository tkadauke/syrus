require "rails_helper"

RSpec.describe "Smart folders", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  describe "retired HTML management endpoints" do
    it "does not route smart folder management endpoints" do
      [
        [ :post, "/smart_folders" ],
        [ :patch, "/smart_folders/legacy/1" ],
        [ :delete, "/smart_folders/legacy/1" ],
        [ :patch, "/smart_folders/1" ],
        [ :delete, "/smart_folders/1" ]
      ].each do |method, path|
        expect {
          Rails.application.routes.recognize_path(path, method: method)
        }.to raise_error(ActionController::RoutingError), "#{method.upcase} #{path} should not route"
      end
    end

    it "serves the SPA shell for retired smart folder GET paths instead of 404ing" do
      [ "/smart_folders", "/smart_folders/legacy" ].each do |path|
        get path

        expect(response).to have_http_status(:ok), "expected #{path} to serve the SPA shell"
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end
  end
end
