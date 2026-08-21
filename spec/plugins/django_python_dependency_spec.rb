require "rails_helper"

# Exercises the plugin dependency cascade mechanism (AdminPluginCascadeActions,
# Admin::PluginDependencyGraph, Admin::PluginDisableGuard) end-to-end through
# the real bearer-token admin API, against the actual `django`/`python`
# dependency pair declared in plugins/django/lib/django/engine.rb and
# plugins/python/lib/python/engine.rb — not a synthetic pair invented for the
# test (see spec/requests/api/v1/admin/plugins_spec.rb for the generic
# mechanism tests, and spec/plugins/rails_ruby_dependency_spec.rb for the
# same mechanism exercised against syrus-rails/ruby).
RSpec.describe "django depends_on python plugin cascade", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  before do
    admin_token
    Syrus::PluginRegistry.reset!

    # Mirrors plugins/python/lib/python/engine.rb's after_initialize registration.
    Syrus::PluginRegistry.register(
      name:             "python",
      version:          Python::VERSION,
      description:      "Python-generic intelligence: uv/poetry/pip prepare detection, " \
                         "pytest JSON-report grader detail, venv/uv prompt reminder",
      homepage:         "https://github.com/tkadauke/syrus",
      prepare_priority: 30,
      provides: {
        prepare_detector: Python::PrepareDetector,
        grader_augmentor: Python::GraderAugmentor,
        prompt_injector:  Python::PromptContext
      }
    )

    # Mirrors plugins/django/lib/django/engine.rb's after_initialize registration.
    Syrus::PluginRegistry.register(
      name:        "django",
      version:     Django::VERSION,
      description: "Django framework intelligence: preview hosting via manage.py " \
                   "runserver, migrate-based seeding with a documented fixtures/seed " \
                   "convention",
      homepage:    "https://github.com/tkadauke/syrus",
      depends_on:  [ "python" ],
      provides: {
        preview_provider: Django::PreviewProvider
      }
    )
  end

  after { Syrus::PluginRegistry.reset! }

  it "cascades enabling django to enable python" do
    PluginRecord.find_by!(name: "python").update!(enabled: false)
    PluginRecord.find_by!(name: "django").update!(enabled: false)

    post "/api/v1/admin/plugins/django/enable", headers: auth

    expect(response).to have_http_status(:ok)
    expect(PluginRecord.find_by!(name: "python").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "django").enabled).to be(true)
  end

  it "warns instead of disabling python while django is enabled" do
    post "/api/v1/admin/plugins/python/disable", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["requires_confirmation"]).to be(true)
    expect(body["plugin_name"]).to eq("python")
    expect(body["dependents"]).to eq([ "django" ])
    expect(PluginRecord.find_by!(name: "python").enabled).to be(true)
    expect(PluginRecord.find_by!(name: "django").enabled).to be(true)
  end

  it "cascades disabling python's dependents once confirmed" do
    post "/api/v1/admin/plugins/python/disable", params: { confirm_cascade: true }, headers: auth

    expect(response).to have_http_status(:ok)
    names = parse_body.fetch("plugins").map { |p| p["name"] }
    expect(names).to include("python", "django")
    expect(PluginRecord.find_by!(name: "python").enabled).to be(false)
    expect(PluginRecord.find_by!(name: "django").enabled).to be(false)
  end
end
