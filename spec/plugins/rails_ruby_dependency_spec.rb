require "rails_helper"

# Exercises the plugin dependency cascade mechanism (AdminPluginCascadeActions,
# Admin::PluginDependencyGraph, Admin::PluginDisableGuard) end-to-end through
# the real bearer-token admin API, against the actual `syrus-rails`/`ruby`
# dependency pair declared in plugins/rails/lib/syrus_rails/engine.rb and
# plugins/ruby/lib/ruby/engine.rb — not a synthetic pair invented for the
# test (see spec/requests/api/v1/admin/plugins_spec.rb for the generic
# mechanism tests).
RSpec.describe "syrus-rails depends_on ruby plugin cascade", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  before do
    admin_token
    Syrus::PluginRegistry.reset!

    # Mirrors plugins/ruby/lib/ruby/engine.rb's after_initialize registration
    # (the in-memory registry is reset for every test example; see
    # config/initializers/plugin_registry.rb).
    Syrus::PluginRegistry.register(
      name:             "ruby",
      version:          Ruby::VERSION,
      description:      "Ruby-generic intelligence: RSpec grader detail, RSpec output parsing, " \
                         "SimpleCov analysis, Gemfile prepare detection",
      homepage:         "https://github.com/tkadauke/syrus",
      prepare_priority: 10,
      provides: {
        coverage_analyzer:  Ruby::SimpleCovAnalyzer,
        grader_augmentor:   Ruby::GraderAugmentor,
        prepare_detector:   Ruby::PrepareDetector,
        test_result_parser: Ruby::RspecParser
      }
    )

    # Mirrors plugins/rails/lib/syrus_rails/engine.rb's after_initialize registration.
    Syrus::PluginRegistry.register(
      name:        "syrus-rails",
      version:     SyrusRails::VERSION,
      description: "Ruby on Rails intelligence",
      homepage:    "https://github.com/tkadauke/syrus",
      depends_on:  [ "ruby" ],
      provides: {
        mcp_tool_set:      SyrusRails::McpToolSet,
        artifact_renderer: [ SyrusRails::SchemaErdRenderer, SyrusRails::MigrationDiffRenderer ],
        prompt_injector:   SyrusRails::PromptContext,
        preview_provider:  SyrusRails::PreviewProvider
      }
    )
  end

  after { Syrus::PluginRegistry.reset! }

  it "cascades enabling syrus-rails to enable ruby" do
    PluginRecord.find_by!(name: "ruby").update!(enabled: false)
    PluginRecord.find_by!(name: "syrus-rails").update!(enabled: false)

    post "/api/v1/admin/plugins/syrus-rails/enable", headers: auth

    expect(response).to have_http_status(:ok)
    expect(PluginRecord.find_by!(name: "ruby").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "syrus-rails").enabled).to be(true)
  end

  it "warns instead of disabling ruby while syrus-rails is enabled" do
    post "/api/v1/admin/plugins/ruby/disable", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["requires_confirmation"]).to be(true)
    expect(body["plugin_name"]).to eq("ruby")
    expect(body["dependents"]).to eq([ "syrus-rails" ])
    expect(PluginRecord.find_by!(name: "ruby").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "syrus-rails").enabled).to be(true)
  end

  it "cascades disabling ruby's dependents once confirmed" do
    post "/api/v1/admin/plugins/ruby/disable", params: { confirm_cascade: true }, headers: auth

    expect(response).to have_http_status(:ok)
    names = parse_body.fetch("plugins").map { |p| p["name"] }
    expect(names).to include("ruby", "syrus-rails")
    expect(PluginRecord.find_by!(name: "ruby").enabled).to be(false)
    expect(PluginRecord.find_by!(name: "syrus-rails").enabled).to be(false)
  end
end
