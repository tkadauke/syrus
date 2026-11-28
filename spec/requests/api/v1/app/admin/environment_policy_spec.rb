require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/environment_policy", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:path) { "/api/v1/app/admin/environment_policy" }

  it "requires an administrator" do
    get path
    expect(response).to have_http_status(:unauthorized)

    sign_in_as(Factories.user)
    get path
    expect(response).to have_http_status(:forbidden)
  end

  it "returns safe registry status and the effective policy" do
    sign_in_as(admin)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("SYRUS_RUNTIME_IMAGE_REGISTRY_URL").and_return(nil)

    get path

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body.dig("registry", "configured")).to be(false)
    expect(body.dig("policy", "verification", "blocked_severities")).to eq(%w[critical high])
    expect(body.dig("policy", "scratch", "profile")).to eq("standard")
  end

  it "persists and audits a valid policy" do
    sign_in_as(admin)
    policy = CoworkerEnvironmentPolicy.current.deep_merge(
      "builder" => { "max_concurrent_builds" => 4 },
      "verification" => { "prohibited_packages" => [ "telnet" ] },
      "scratch" => { "profile" => "executable_scratch", "size" => "2g" }
    )

    expect {
      patch path, params: { environment_policy: policy }
    }.to change { AdminAction.where(action: "update_coworker_environment_policy").count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.coworker_environment_policy.dig("builder", "max_concurrent_builds")).to eq(4)
  end

  it "rejects an invalid ABI window without changing policy" do
    sign_in_as(admin)
    policy = CoworkerEnvironmentPolicy.current.deep_merge("base" => { "supported_abi_min" => 3, "supported_abi_max" => 2 })

    patch path, params: { environment_policy: policy }

    expect(response).to have_http_status(:unprocessable_content)
    expect(AppSetting.current.reload.coworker_environment_policy).to be_nil
  end
end
