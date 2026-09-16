require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/retention_settings", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user }

  # Real RetentionPolicyRegistry entry (existing "notification" AppSetting
  # column + table) so the payload/update paths exercise a real column
  # instead of a made-up one, without asserting on the full
  # (plugin-extendable) registry list core specs must not enumerate.
  let(:definition) { RetentionPolicyRegistry.fetch(:notification) }

  def parse_body
    JSON.parse(response.body)
  end

  before do
    allow(RetentionPolicyRegistry).to receive(:definitions).and_return([ definition ])
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/retention_settings"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/retention_settings"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "builds the table payload from the registry, current AppSetting values, and cached size snapshots" do
    sign_in_as(admin)
    AppSetting.current.update!(notification_retention_days: 10)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    allow(TableSizeEstimator).to receive(:estimate).with("notifications").and_return(
      TableSizeEstimator::Result.new(table_name: "notifications", row_count_estimate: 1000, byte_size_estimate: 200_000)
    )
    RetentionSizeSnapshotJob.perform_now

    get "/api/v1/app/admin/retention_settings"

    expect(response).to have_http_status(:ok)
    row = parse_body["tables"].find { |t| t["key"] == "notification" }
    expect(row).to include(
      "table_name" => "notifications",
      "setting_key" => "notification_retention_days",
      "unit" => "days",
      "retention_value" => 10,
      "row_count_estimate" => 1000,
      "byte_size_estimate" => 200_000,
      "estimated_max_byte_size" => 200_000
    )
    expect(row["description"]).to be_present
    expect(parse_body["retention_available_space_override_gb"]).to eq(0)
  end

  it "omits sizing fields for a table with no cached snapshot yet" do
    sign_in_as(admin)

    get "/api/v1/app/admin/retention_settings"

    expect(response).to have_http_status(:ok)
    row = parse_body["tables"].find { |t| t["key"] == "notification" }
    expect(row["row_count_estimate"]).to be_nil
    expect(row["estimated_max_byte_size"]).to be_nil
  end

  it "updates a table's retention setting" do
    sign_in_as(admin)
    AppSetting.current.update!(notification_retention_days: 30)

    patch "/api/v1/app/admin/retention_settings", params: {
      retention_settings: { notification_retention_days: 60 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.notification_retention_days).to eq(60)
    expect(parse_body["message"]).to eq("Retention settings updated.")
  end

  it "permits 0 as the infinite-retention sentinel" do
    sign_in_as(admin)
    AppSetting.current.update!(notification_retention_days: 30)

    patch "/api/v1/app/admin/retention_settings", params: {
      retention_settings: { notification_retention_days: 0 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.notification_retention_days).to eq(0)
  end

  it "rejects a negative retention value without persisting it" do
    sign_in_as(admin)
    AppSetting.current.update!(notification_retention_days: 30)

    patch "/api/v1/app/admin/retention_settings", params: {
      retention_settings: { notification_retention_days: -1 }
    }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("validation_failed")
    expect(AppSetting.current.reload.notification_retention_days).to eq(30)
  end

  it "updates the manual available-space override" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/retention_settings", params: {
      retention_settings: { retention_available_space_override_gb: 500 }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.retention_available_space_override_gb).to eq(500)
    expect(parse_body["retention_available_space_override_gb"]).to eq(500)
  end

  it "ignores unregistered keys" do
    sign_in_as(admin)

    patch "/api/v1/app/admin/retention_settings", params: {
      retention_settings: { notification_retention_days: 45, mode: "simple" }
    }

    expect(response).to have_http_status(:ok)
    expect(AppSetting.current.reload.notification_retention_days).to eq(45)
    expect(AppSetting.current.mode).to eq("advanced")
  end
end
