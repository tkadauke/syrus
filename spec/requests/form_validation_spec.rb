require "rails_helper"

RSpec.describe "Form validation feedback", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  it "mounts global form state controllers on the body" do
    get new_job_path

    expect(response).to be_successful
    expect(response.body).to include('data-controller="form-validation checkbox-persistence"')
  end

  it "keeps the new job repository and prompt fields browser-validatable" do
    Factories.repository(user: user, owner: "acme", name: "widgets")

    get new_job_path

    expect(response.body).to include('name="repository_id"')
    expect(response.body).to include('id="repository_id" required')
    expect(response.body).to include('name="prompt"')
    expect(response.body).to include('id="prompt"')
    expect(response.body).to include("required")
  end
end
