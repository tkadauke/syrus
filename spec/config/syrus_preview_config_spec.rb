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
    expect(preview_script).to include("rm -f app/assets/builds/.vite/manifest.json app/assets/builds/tailwind.css")
    # Watchers are long-running development processes rather than reliable
    # build-completion signals. Synchronous builds have to come first; the
    # watchers then follow so a live preview still rebuilds on edits.
    expect(preview_script).to include("bin/rails tailwindcss:build")
    expect(preview_script).to include("bin/rails tailwindcss:watch")
    expect(preview_script.index("bin/rails tailwindcss:build"))
      .to be < preview_script.index("bin/rails tailwindcss:watch")
    expect(preview_script).to include("npm run build > log/vite.log")
    expect(preview_script).to include("npm run build -- --watch")
    expect(preview_script.index("npm run build > log/vite.log"))
      .to be < preview_script.index("npm run build -- --watch")
    # CI serves immutable sources for one test run. Keeping both development
    # watchers alive there can race the completed output and contend with the
    # Rails process while Playwright waits for the server to become healthy.
    expect(preview_script).to include('if [ -z "${CI:-}" ]; then')
    expect(preview_script.index('if [ -z "${CI:-}" ]; then'))
      .to be < preview_script.index("npm run build -- --watch")
    expect(preview_script).to include("wait_for_file app/assets/builds/.vite/manifest.json log/vite.log")
    expect(preview_script).to include("wait_for_file app/assets/builds/tailwind.css log/tailwind.log")

    rails_start_index = preview_script.index("bin/rails server")
    expect(rails_start_index).to be_present
    expect(preview_script.index("wait_for_file app/assets/builds/.vite/manifest.json log/vite.log")).to be < rails_start_index
    expect(preview_script.index("wait_for_file app/assets/builds/tailwind.css log/tailwind.log")).to be < rails_start_index
  end
end
