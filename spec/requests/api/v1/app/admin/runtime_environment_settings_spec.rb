require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/runtime_environment_settings", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:path) { "/api/v1/app/admin/runtime_environment_settings" }

  it "requires an administrator" do
    get path
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(Factories.user)
    get path
    expect(response).to have_http_status(:forbidden)
  end

  it "returns registry status, policy defaults, and build-network rules without exposing passwords" do
    sign_in_as(admin)
    RuntimeImageBuildNetworkRule.create!(source_class: "internal_mirror", host: "mirror.example.test", required: true, enabled: true, actor: "user:#{admin.id}")

    get path

    expect(response).to have_http_status(:ok)
    body = response.parsed_body
    expect(body.dig("policy", "builder", "max_concurrent_builds")).to eq(2)
    expect(body.dig("policy", "runtime", "mount_profile")).to eq("standard")
    expect(body["network_rules"].sole).to include("host" => "mirror.example.test", "required" => true)
    expect(body.to_json).not_to include("builder_password")
  end

  it "persists encrypted registry credentials and validated policy with an audit row" do
    sign_in_as(admin)

    patch path, params: { runtime_environment_settings: {
      registry: { url: "https://registry.example.test", repository_prefix: "internal/syrus",
                  builder_username: "builder", builder_password: "build-secret" },
      policy: {
        builder: { max_concurrent_builds: 5 },
        base: { supported_abi_min: 1, supported_abi_max: 1 },
        runtime: { mount_profile: "executable_scratch", scratch_size: "2g" }
      }
    } }, as: :json

    expect(response).to have_http_status(:ok)
    setting = AppSetting.current.reload
    expect(setting.runtime_image_registry_builder_password).to eq("build-secret")
    expect(setting.runtime_environment_policy.dig("builder", "max_concurrent_builds")).to eq(5)
    expect(setting.runtime_environment_policy["base"]).to include("supported_abi_min" => 1, "supported_abi_max" => 1)
    expect(setting.runtime_environment_policy.dig("runtime", "mount_profile")).to eq("executable_scratch")
    expect(AdminAction.last).to have_attributes(user: admin, action: "runtime_environment_settings.update")
    expect(response.parsed_body.dig("registry", "credentials", "builder")).to include("password_set" => true)
  end

  it "rejects invalid pressure thresholds" do
    sign_in_as(admin)
    patch path, params: { runtime_environment_settings: { policy: { cache: { high_pressure_percent: 95, critical_pressure_percent: 90 } } } }, as: :json

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body.dig("error", "code")).to eq("validation_failed")
  end
end
