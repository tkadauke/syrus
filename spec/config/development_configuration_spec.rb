require "rails_helper"

RSpec.describe "development configuration" do
  let(:development_config) { Rails.root.join("config/environments/development.rb").read }

  it "allows the preview proxy hostnames without changing production host authorization" do
    expect(development_config).to include('[ "syrus-preview", "preview", ENV["SYRUS_PREVIEW_INTERNAL_HOST"] ]')
    expect(development_config).to include("config.hosts.concat(preview_hosts)")
  end
end
