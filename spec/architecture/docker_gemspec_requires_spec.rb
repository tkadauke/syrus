require "rails_helper"

# Plugin manifests are no longer Bundler path gems. Keeping plugin source out
# of the bundle-install layer means a plugin-only change can reuse that layer;
# the complete built-in plugin tree still has to reach the runtime image.
RSpec.describe "plugin source in the Docker build" do
  DOCKERFILE = Rails.root.join("Dockerfile")

  let(:lines) { File.readlines(DOCKERFILE) }
  let(:bundle_install_line) { lines.index { |line| line.match?(/^RUN\s+bundle install\b/) } }
  let(:plugin_copy_line) { lines.index { |line| line.match?(%r{^COPY\s+plugins/\s+\./plugins/}) } }

  it "installs gems before copying plugin source" do
    expect(bundle_install_line).not_to be_nil
    expect(plugin_copy_line).to be > bundle_install_line
  end
end
