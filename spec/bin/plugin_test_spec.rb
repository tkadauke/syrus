require "rails_helper"
require "open3"

RSpec.describe "bin/plugin-test" do
  let(:fixture) { Rails.root.join("spec/fixtures/relocatable_plugin") }

  def run_plugin(path, mode: "test")
    Open3.capture2e({ "SYRUS_PLUGIN_TEST_MODE" => mode, "SYRUS_PLUGIN_TEST_JSON" => "1", "SYRUS_VERSION" => "0.1.0" },
      Rails.root.join("bin/plugin-test").to_s, path.to_s, chdir: Rails.root.to_s)
  end

  def with_built_fixture
    Dir.mktmpdir do |directory|
      plugin = Pathname.new(directory).join("relocatable_plugin")
      FileUtils.cp_r(fixture, plugin)
      output, status = Open3.capture2e(Rails.root.join("bin/build-plugin-frontend").to_s, plugin.to_s, chdir: Rails.root.to_s)
      raise output unless status.success?
      plugin.join("spec/relocatable_plugin_spec.rb").write(<<~RUBY)
        require ENV.fetch("SYRUS_HOST_ROOT") + "/spec/spec_helper"
        require ENV.fetch("SYRUS_HOST_ROOT") + "/config/environment"
        require "rspec/rails"
        RSpec.describe("plugin specs") { it("runs") { expect(RelocatablePlugin).to be_a(Module) } }
      RUBY
      yield plugin
    end
  end

  it "validates and tests a passing plugin with a stable summary" do
    with_built_fixture do |plugin|
      output, status = run_plugin(plugin)

      expect(status).to be_success, output
      expect(JSON.parse(output.lines.last)).to include("version" => 1, "validation" => "passed", "tests" => "passed", "exit_code" => 0)
    end
  end

  it "reports a validation failure and a nonzero exit" do
    with_built_fixture do |plugin|
      gemspec = plugin.join("relocatable_plugin.gemspec")
      gemspec.write(gemspec.read.sub('>= 0.1.0', '>= 999.0'))

      output, status = run_plugin(plugin, mode: "validate")
      expect(status).not_to be_success
      expect(JSON.parse(output.lines.last)).to include("validation" => "failed", "tests" => "not_run", "exit_code" => 1)
    end
  end

  it "reports a failing plugin spec and a nonzero exit" do
    with_built_fixture do |plugin|
      plugin.join("spec/failing_spec.rb").write("RSpec.describe('failure') { it { expect(true).to be(false) } }\n")

      output, status = run_plugin(plugin)
      expect(status).not_to be_success
      expect(JSON.parse(output.lines.last)).to include("validation" => "passed", "tests" => "failed", "exit_code" => 1)
    end
  end
end
