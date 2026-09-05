require "rails_helper"

RSpec.describe "Scheduled tasks", type: :request do
  let(:user)       { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  let(:valid_cron_attrs) do
    {
      name: "Weekly tests",
      kind: "cron",
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip",
      prompt: "Write missing tests."
    }
  end

  it "requires authentication on index" do
    get "/scheduled_tasks"
    expect(response).to redirect_to(new_session_path).or redirect_to(new_user_path)
  end

  context "signed in" do
    before { sign_in_as(user) }

    describe "GET /repositories/:id/scheduled_tasks/new" do
      it "serves the React scheduled task form shell" do
        get "/repositories/#{repository.id}/scheduled_tasks/new"
        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end

    describe "GET /scheduled_tasks/:id/edit" do
      it "serves the React scheduled task edit shell" do
        task = ScheduledTasks::Task.create!(repository: repository, user: user, **valid_cron_attrs)
        get "/scheduled_tasks/#{task.id}/edit"

        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end

    describe "GET /scheduled_tasks" do
      it "serves the React scheduled tasks shell" do
        get "/scheduled_tasks"
        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end

    describe "GET /scheduled_tasks/:id" do
      it "serves the React scheduled task detail shell" do
        task = ScheduledTasks::Task.create!(repository: repository, user: user, **valid_cron_attrs)
        get "/scheduled_tasks/#{task.id}"
        expect(response).to be_successful
        expect(response.body).to include('id="syrus-spa-root"')
      end
    end

    describe "legacy HTML endpoints" do
      it "does not route retired scheduled-task HTML endpoints" do
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/legacy", method: :get)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/legacy/1", method: :get)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/legacy/1/edit", method: :get)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/1", method: :patch)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/1", method: :delete)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/1/pause", method: :post)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/1/resume", method: :post)
        }.to raise_error(ActionController::RoutingError)
        expect {
          Rails.application.routes.recognize_path("/scheduled_tasks/1/fire_now", method: :post)
        }.to raise_error(ActionController::RoutingError)
      end
    end
  end
end
