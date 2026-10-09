require "rails_helper"

RSpec.describe "API: /api/v1/admin/pending_actions/invoke", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) { admin; Factories.user(admin: false) }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }
  let(:job) { Factories.job_with_run(user: admin) }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  around do |example|
    original_registry = PendingActions::REGISTRY.dup
    spec_action_class
    spec_argument_error_action_class
    spec_admin_only_action_class
    example.run
  ensure
    PendingActions::REGISTRY.replace(original_registry)
  end

  let(:executions) { [] }

  let(:spec_action_class) do
    executed = executions
    Class.new(PendingActions::Base) do
      action_key "spec_api_action"

      define_method(:perform) do
        executed << payload
        Job.find(payload.fetch("job_id"))
      end

      def validate_payload(errors)
        errors.add(:payload, "job_id is required") if payload["job_id"].blank?
      end
    end
  end

  let(:spec_argument_error_action_class) do
    Class.new(PendingActions::Base) do
      action_key "spec_api_argument_error_action"

      def perform
        raise ArgumentError, "Run not found."
      end
    end
  end

  let(:spec_admin_only_action_class) do
    Class.new(PendingActions::Base) do
      action_key "spec_api_admin_only_action"
      admin_only!

      def perform
        nil
      end
    end
  end

  it "invokes an operation by key and returns its result" do
    post "/api/v1/admin/pending_actions/invoke",
         params: {
           action_key: "spec_api_action",
           reason: "operator requested repair",
           payload: { job_id: job.id }
         },
         headers: auth(admin_token)

    expect(response).to have_http_status(:ok)
    expect(executions).to eq([ { "job_id" => job.id.to_s } ])
    expect(parse_body).to include(
      "ok" => true,
      "action_key" => "spec_api_action",
      "result" => include("type" => "Job", "id" => job.id, "slug" => job.slug)
    )
  end

  it "rejects payloads refused by the operation before executing" do
    post "/api/v1/admin/pending_actions/invoke",
         params: {
           action_key: "spec_api_action",
           reason: "operator requested repair",
           payload: {}
         },
         headers: auth(admin_token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("invalid_pending_action_payload")
    expect(parse_body.dig("error", "message")).to include("job_id is required")
    expect(executions).to be_empty
  end

  it "requires a reason at the API level" do
    post "/api/v1/admin/pending_actions/invoke",
         params: {
           action_key: "spec_api_action",
           payload: { job_id: job.id }
         },
         headers: auth(admin_token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "message")).to include("Reason is required")
    expect(executions).to be_empty
  end

  it "refuses an admin-only operation for a non-admin" do
    post "/api/v1/admin/pending_actions/invoke",
         params: {
           action_key: "spec_api_admin_only_action",
           reason: "operator requested repair",
           payload: {}
         },
         headers: auth(non_admin_token)

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "audits every successful invocation with the acting user, payload, and reason" do
    expect {
      post "/api/v1/admin/pending_actions/invoke",
           params: {
             action_key: "spec_api_action",
             reason: "operator requested repair",
             payload: { job_id: job.id }
           },
           headers: auth(admin_token)
    }.to change(AdminAction, :count).by(1)

    audit = AdminAction.order(:id).last
    expect(audit.user).to eq(admin)
    expect(audit.action).to eq("pending_action_spec_api_action")
    expect(audit.params).to include(
      "source" => "api",
      "action" => "spec_api_action",
      "reason" => "operator requested repair",
      "payload" => { "job_id" => job.id.to_s },
      "result" => include("type" => "Job", "id" => job.id, "slug" => job.slug)
    )
  end

  it "returns ArgumentError failures as client errors" do
    post "/api/v1/admin/pending_actions/invoke",
         params: {
           action_key: "spec_api_argument_error_action",
           reason: "operator requested repair",
           payload: {}
         },
         headers: auth(admin_token)

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("pending_action_operation_failed")
    expect(parse_body.dig("error", "message")).to eq("Run not found.")
  end
end
