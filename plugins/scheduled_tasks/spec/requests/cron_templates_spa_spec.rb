require "rails_helper"

RSpec.describe "Cron templates", type: :request do
  let(:user) { Factories.user }

  let(:valid_attrs) do
    {
      name: "Weekly dependency bump",
      prompt: "Bump outdated gems.",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      enabled: true
    }
  end

  it "requires authentication on index" do
    get "/cron_templates"
    expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    it "serves the React cron template index shell" do
      get "/cron_templates"

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React new template shell" do
      get new_cron_template_path

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React template detail shell" do
      template = ScheduledTasks::CronTemplate.create!(valid_attrs.merge(user: user))

      get cron_template_path(template)

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "serves the React edit template shell" do
      template = ScheduledTasks::CronTemplate.create!(valid_attrs.merge(user: user))

      get edit_cron_template_path(template)

      expect(response).to be_successful
      expect(response.body).to include('id="syrus-spa-root"')
    end

    it "does not route the retired legacy HTML cron-template endpoints" do
      expect {
        Rails.application.routes.recognize_path("/cron_templates/legacy", method: :get)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/cron_templates/legacy/new", method: :get)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/cron_templates/legacy/1", method: :get)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/cron_templates", method: :post)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/cron_templates/1", method: :patch)
      }.to raise_error(ActionController::RoutingError)
      expect {
        Rails.application.routes.recognize_path("/cron_templates/1", method: :delete)
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
