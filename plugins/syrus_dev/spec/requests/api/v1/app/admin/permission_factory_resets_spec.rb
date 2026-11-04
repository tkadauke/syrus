require "rails_helper"

RSpec.describe "API: permission factory resets", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:non_admin) { Factories.user(admin: false) }
  let!(:owner) { Factories.user }

  def body = JSON.parse(response.body)

  before { PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true) }

  it "requires authentication and admin authorization" do
    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "user", scope_id: owner.id }
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(non_admin)
    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "user", scope_id: owner.id }
    expect(response).to have_http_status(:forbidden)
  end

  it "is unavailable while the plugin is disabled" do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)
    sign_in_as(admin)

    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "instance" }

    expect(response).to have_http_status(:not_found)
    expect(body.fetch("error")).to eq("syrus_dev_plugin_disabled")
  end

  it "previews exact counts and retained data, then returns completion and audit references" do
    sign_in_as(admin)
    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "user", scope_id: owner.id }

    expect(response).to have_http_status(:ok)
    expect(body).to include(
      "scope_type" => "user",
      "scope_id" => owner.id.to_s,
      "default_version" => "permissions-factory@v1",
      "instance_confirmation" => nil
    )
    expect(body.fetch("counts").keys).to contain_exactly(
      "rules", "leases", "authorized_invocations", "pending_requests", "resumptions",
      "profile_selections", "factory_rules_to_create", "factory_presets_to_create"
    )
    expect(body.fetch("retained_data")).to include("audit_history", "users", "repositories", "permission_reset_audits")

    post "/api/v1/app/admin/permission_factory_resets", params: {
      scope_type: "user", scope_id: owner.id, confirmation_digest: body.fetch("confirmation_digest")
    }

    expect(response).to have_http_status(:ok)
    expect(body).to include("outcome" => "succeeded", "changed" => true)
    expect(body.fetch("audit")).to include("id" => kind_of(Integer), "default_version" => "permissions-factory@v1")
  end

  it "requires the typed phrase for an instance reset" do
    sign_in_as(admin)
    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "instance" }
    digest = body.fetch("confirmation_digest")
    expect(body.fetch("instance_confirmation")).to eq("RESET INSTANCE")

    post "/api/v1/app/admin/permission_factory_resets", params: {
      scope_type: "instance", confirmation_digest: digest, typed_confirmation: "reset instance"
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("invalid_reset_request")
  end

  it "rejects a stale preview without applying it" do
    sign_in_as(admin)
    post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "user", scope_id: owner.id }
    digest = body.fetch("confirmation_digest")
    PermissionRule.create!(
      owner_user: owner, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_role_keys: [], capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      resource_type: "job", resource_scope: {}, policy: "allow", constraints: {}, policy_layer: "agent",
      source: "operator", provenance: {}, created_by_user: owner, updated_by_user: owner
    )

    post "/api/v1/app/admin/permission_factory_resets", params: {
      scope_type: "user", scope_id: owner.id, confirmation_digest: digest
    }

    expect(response).to have_http_status(:conflict)
    expect(body.dig("error", "code")).to eq("stale_preview")
    expect(PermissionRule.active.where(owner_user: owner, source: "operator")).to exist
  end

  it "reports the second converged reset as unchanged" do
    sign_in_as(admin)
    2.times do
      post "/api/v1/app/admin/permission_factory_resets/preview", params: { scope_type: "user", scope_id: owner.id }
      post "/api/v1/app/admin/permission_factory_resets", params: {
        scope_type: "user", scope_id: owner.id, confirmation_digest: body.fetch("confirmation_digest")
      }
    end

    expect(body).to include("outcome" => "succeeded", "changed" => false)
  end
end
