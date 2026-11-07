require "open3"
require "rails_helper"
require "tmpdir"

RSpec.describe "bin/plugin-boundary-audit" do
  let(:root) { Rails.root.to_s }

  def build_synthetic_repository(directory)
    synthetic_root = Pathname.new(directory)
    synthetic_root.join("plugins/weather/lib").mkpath
    synthetic_root.join("plugins/weather/config").mkpath
    synthetic_root.join("app/services").mkpath
    synthetic_root.join("plugins/weather/lib/weather.rb").write(<<~RUBY)
      syrus_plugin "weather" do
      end
    RUBY
    synthetic_root.join("plugins/weather/config/plugin_ownership.yml").write(<<~YAML)
      plugin: weather
      ownership:
        configuration_keys: [weather_api_key]
        documentation_paths: [plugins/weather/docs]
        frontend_contributions: [weather/Forecast]
        problem_codes: [weather_unavailable]
        route_prefixes: [/api/v1/app/weather]
        step_kinds: [weather_forecast]
        tables: [weather_forecasts]
        target_types: [weather_station]
        tools: [read_forecast]
        vocabulary: [forecast_widget]
      compatibility_quarantine:
        app/services/dashboard.rb: 1
    YAML
    synthetic_root.join("app/services/dashboard.rb").write("forecast_widget = true\n")
    synthetic_root.join("Gemfile").write("gem \"weather\", path: \"plugins/weather\"\n")
    system("git", "init", "--quiet", synthetic_root.to_s, exception: true)
    system("git", "-C", synthetic_root.to_s, "add", ".", exception: true)
    system(
      "git", "-C", synthetic_root.to_s,
      "-c", "user.name=Syrus Specs", "-c", "user.email=syrus@example.test",
      "commit", "--quiet", "-m", "Synthetic plugin fixture", exception: true
    )
    synthetic_root
  end

  it "removes the selected plugin plus transitive dependents in a temporary copy", :requires_git_checkout do
    command = [
      "test ! -d plugins/ruby",
      "test ! -d plugins/rails",
      "test -d plugins/python",
      "! grep -q 'plugins/ruby' Gemfile",
      "! grep -q 'plugins/rails' Gemfile",
      "grep -q 'plugins/python' Gemfile"
    ].join(" && ")

    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_PATH" => "#{root}/vendor/bundle", "BUNDLE_APP_CONFIG" => "#{root}/.bundle" },
      "bin/plugin-boundary-audit",
      "ruby",
      "--command",
      command,
      chdir: root
    )

    expect(status).to be_success, "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stdout).to include("Removed plugins: ruby, syrus-rails")
    expect(stdout).to include("physical-removal audit (physical removability)")
    expect(stdout).to include("Result: PASS")
  end

  it "reports vocabulary ownership separately from physical removability", :requires_git_checkout do
    Dir.mktmpdir("plugin-boundary-audit") do |directory|
      synthetic_root = build_synthetic_repository(directory)
      stdout, stderr, status = Open3.capture3(
        {
          "BUNDLE_PATH" => "#{root}/vendor/bundle",
          "BUNDLE_APP_CONFIG" => "#{root}/.bundle",
          "PLUGIN_BOUNDARY_AUDIT_ROOT" => synthetic_root.to_s
        },
        "bin/plugin-boundary-audit",
        "weather",
        "--command",
        "true",
        chdir: root
      )

      expect(status).to be_success, "stdout=#{stdout}\nstderr=#{stderr}"
      expect(stdout).to include("vocabulary-ownership audit")
      expect(stdout).to include("no core reimplementation growth")
      expect(stdout).to include("physical-removal audit (physical removability)")
    end
  end

  it "reports unknown plugins before creating a temporary copy" do
    stdout, stderr, status = Open3.capture3(
      { "BUNDLE_PATH" => "#{root}/vendor/bundle", "BUNDLE_APP_CONFIG" => "#{root}/.bundle" },
      "bin/plugin-boundary-audit",
      "missing-plugin",
      "--command",
      "true",
      chdir: root
    )

    expect(status.exitstatus).to eq(64), "stdout=#{stdout}\nstderr=#{stderr}"
    expect(stderr).to include("Unknown bundled plugin: missing-plugin")
  end
end
