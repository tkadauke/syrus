require "rails_helper"

RSpec.describe "Smart folders", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  describe "retired HTML management endpoints" do
    it "does not route smart folder management endpoints" do
      [
        [ :get, "/smart_folders" ],
        [ :get, "/smart_folders/legacy" ],
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
  end
end
