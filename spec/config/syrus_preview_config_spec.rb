require "rails_helper"
require "yaml"

RSpec.describe "Syrus self-preview configuration" do
  let(:repo_root) { Rails.root }
  let(:syrus_yml) do
    YAML.safe_load(
      repo_root.join(".syrus.yml").read,
      aliases: true
    )
  end
  let(:preview_script_path) { repo_root.join("bin/syrus-preview-dev") }
  let(:preview_script) { preview_script_path.read }

  it "starts the Rails preview through the SPA-aware helper" do
    preview_config = syrus_yml.fetch("preview")

    expect(preview_config.fetch("start")).to eq("bin/syrus-preview-dev")
    expect(preview_config.fetch("logs")).to include("log/development.log", "log/vite.log", "log/tailwind.log")
  end

  it "builds frontend assets before starting Rails" do
    expect(preview_script_path).to be_executable
    expect(preview_script).to include("rm -f app/assets/builds/spa.js app/assets/builds/tailwind.css")
    expect(preview_script).to include("bin/rails tailwindcss:watch")
    expect(preview_script).to include("npm run build -- --watch")
    expect(preview_script).to include("wait_for_file app/assets/builds/spa.js log/vite.log")
    expect(preview_script).to include("wait_for_file app/assets/builds/tailwind.css log/tailwind.log")

    rails_start_index = preview_script.index("bin/rails server")
    expect(rails_start_index).to be_present
    expect(preview_script.index("wait_for_file app/assets/builds/spa.js log/vite.log")).to be < rails_start_index
    expect(preview_script.index("wait_for_file app/assets/builds/tailwind.css log/tailwind.log")).to be < rails_start_index
  end
end
