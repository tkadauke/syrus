require "rails_helper"

RSpec.describe "App API repository ref-movement actions", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, default_branch: "main") }

  before do
    allow_any_instance_of(DeliveryPolicy).to receive(:promotion_enabled?).and_return(true)
    allow_any_instance_of(DeliveryPolicy).to receive(:promotion_mode).and_return("manual_pr")
    allow_any_instance_of(DeliveryPolicy).to receive(:promotion_source_branch).and_return("develop")
    allow_any_instance_of(DeliveryPolicy).to receive(:promotion_target_branch).and_return("main")
    allow(StepDispatcher).to receive(:start_workflow)
  end

  it "dispatches a promotion for a writable repository" do
    sign_in_as(user)

    expect {
      post "/api/v1/app/repositories/#{repository.id}/ref_movement_actions", params: { action_name: "promote_development_to_release" }, as: :json
    }.to change(RefMovementAction, :count).by(1)

    expect(response).to have_http_status(:ok)
    expect(RefMovementAction.last).to be_dispatched
  end

  it "returns the blocker for an in-flight promotion" do
    sign_in_as(user)
    post "/api/v1/app/repositories/#{repository.id}/ref_movement_actions", params: { action_name: "promote_development_to_release" }, as: :json
    workflow = RefMovementAction.last.workflow

    post "/api/v1/app/repositories/#{repository.id}/ref_movement_actions", params: { action_name: "promote_development_to_release" }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "message")).to include("workflow #{workflow.id}", "queued")
  end
end
