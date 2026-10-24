require "rails_helper"

RSpec.describe "Attention Report API", type: :request do
  let(:user) { Factories.user }

  it "requires authentication" do
    get "/api/v1/app/insights/attention"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns only the signed-in user's report for the selected window" do
    PluginRecord.find_or_create_by!(name: "attention_report").update!(enabled: true)
    Factories.job_record(user: user, kind: "direct", issue_number: nil)
    Factories.job_record(user: Factories.user, kind: "direct", issue_number: nil)
    sign_in_as(user)

    get "/api/v1/app/insights/attention", params: { window_days: 14 }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("window", "days")).to eq(14)
    expect(response.parsed_body.dig("attention", "deciding", "figures", "human_created_jobs", "count")).to eq(1)
    expect(response.parsed_body.dig("metadata", "current_user_only")).to be(true)
  end
end
