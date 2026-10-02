require "rails_helper"

RSpec.describe "website docs" do
  it "mentions plugin-declared credential type names once on the plugins page" do
    body = Rails.root.join("website/src/content/docs/plugins.md").read

    expect(body.scan("Plugins can also declare stable credential type names").size).to eq(1)
  end
end
