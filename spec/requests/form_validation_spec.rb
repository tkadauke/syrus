require "rails_helper"

RSpec.describe "Form validation feedback", type: :request do
  it "serves the React sign-in shell instead of the retired non-SPA layout" do
    get new_session_path

    expect(response).to be_successful
    expect(response.body).to include('id="syrus-spa-root"')
  end
end
