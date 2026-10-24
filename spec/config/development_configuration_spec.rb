require "rails_helper"
require "json"
require "open3"

RSpec.describe "development configuration" do
  def development_hosts(internal_host: nil)
    stdout, stderr, status = Open3.capture3(
      { "RAILS_ENV" => "development", "SYRUS_PREVIEW_INTERNAL_HOST" => internal_host },
      Rails.root.join("bin/rails").to_s,
      "runner",
      'puts JSON.generate(Rails.application.config.hosts.to_a.map(&:to_s))'
    )
    raise stderr unless status.success?

    JSON.parse(stdout.lines.last)
  end

  it "adds the built-in preview hosts while preserving Rails development defaults" do
    hosts = development_hosts

    expect(hosts).to include(".localhost", ".test", "0.0.0.0", "::", "syrus-preview", "preview")
  end

  it "adds the configured preview internal host" do
    expect(development_hosts(internal_host: "custom-preview")).to include("custom-preview")
  end
end
