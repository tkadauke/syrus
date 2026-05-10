require "rails_helper"

RSpec.describe "Form validation feedback", type: :request do
  let(:user) { Factories.user }

  before { sign_in_as(user) }

  it "mounts one validation controller for all rendered forms" do
    get new_job_path

    expect(response).to be_successful
    expect(response.body).to include('data-controller="form-validation"')
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

  it "implements generic invalid-submit handling instead of a job-form-only check" do
    controller_source = Rails.root.join("app/javascript/controllers/form_validation_controller.js").read

    expect(controller_source).to include('addEventListener("invalid", this.boundInvalid, true)')
    expect(controller_source).to include('addEventListener("submit", this.boundSubmit, true)')
    expect(controller_source).to include("form.checkValidity()")
    expect(controller_source).to include("this.showSummary(form)")
    expect(controller_source).not_to include("repository_id")
  end
end
