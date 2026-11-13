require "rails_helper"

RSpec.describe JsonApiVersioning, type: :controller do
  controller(ActionController::API) do
    include JsonApiVersioning

    def hash_payload
      render json: { item: "value" }
    end

    def array_payload
      render json: [ "value" ]
    end
  end

  before do
    routes.draw do
      get "hash_payload" => "anonymous#hash_payload"
      get "array_payload" => "anonymous#array_payload"
    end
  end

  it "prepends the current version to JSON hash responses" do
    get :hash_payload

    expect(response.body).to eq(%({"v":1,"item":"value"}))
  end

  it "does not change non-hash JSON responses" do
    get :array_payload

    expect(response.parsed_body).to eq([ "value" ])
  end
end
