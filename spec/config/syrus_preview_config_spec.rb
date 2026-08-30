require "rails_helper"

RSpec.describe "Syrus preview config" do
  let(:config) do
    YAML.safe_load_file(Rails.root.join(".syrus.yml"), aliases: true)
  end

  it "starts the development preview wrapper so the SPA assets are available" do
    expect(config.dig("preview", "start")).to eq("bin/syrus-preview-dev")
    expect(Rails.root.join("bin/syrus-preview-dev")).to be_executable

    script = Rails.root.join("bin/syrus-preview-dev").read
    expect(script).to include("wait_for_file app/assets/builds/spa.js log/vite.log")
    expect(script).to include("wait_for_file app/assets/builds/tailwind.css log/tailwind.log")
  end

  it "exposes Rails, Vite, and Tailwind logs for preview debugging" do
    expect(config.dig("preview", "logs")).to include(
      "log/development.log",
      "log/vite.log",
      "log/tailwind.log"
    )
  end
end
