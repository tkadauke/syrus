require "rails_helper"

RSpec.describe "parameter log filtering" do
  it "filters API tokens and authorization headers" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)

    expect(filter.filter(
      "api_token" => "syrus_secret",
      "Authorization" => "Bearer syrus_secret"
    )).to eq(
      "api_token" => "[FILTERED]",
      "Authorization" => "[FILTERED]"
    )
  end
end
