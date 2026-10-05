require "rails_helper"
require "open3"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::MinitestGraderType do
  it "registers the minitest type name" do
    expect(described_class.type_name).to eq("minitest")
  end

  it "expands to typed focused review, full landing, and ci graders" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:name)).to eq(%w[minitest minitest-focused minitest-ci])
    expect(steps.first.run).to include("bin/rails test test")
    expect(steps.first.run).to include("bundle exec rake test")
    expect(steps.first.run).to include("bundle exec ruby -Itest test")
    expect(steps.first.run).to include("RAILS_ENV=test bin/rails db:test:prepare")
    expect(steps.first.phases).to eq(%w[landing])
    expect(steps.first.failures).to eq("allow_inherited")
    expect(steps.first.base_retry).to eq(SyrusYml::BaseRetry.new(strategy: "full_command", command: nil))
    expect(steps.first.junit_output).to be_nil
    expect(steps.first.metadata).to include(
      "grader_type" => "minitest",
      "grader_framework" => "minitest",
      "grader_mode" => "full"
    )
    expect(steps.first.metadata["result_outputs"]).to eq([])
    expect(steps.first.metadata.dig("filter_capabilities", "failed_cases")).to be(false)

    expect(steps.second.run).to include(".syrus/minitest-focused-files")
    expect(steps.second.run).to include("bin/rails test $(cat .syrus/minitest-focused-files)")
    expect(steps.second.run).to include("bundle exec ruby -Itest $(cat .syrus/minitest-focused-files)")
    expect(steps.second.phases).to eq(%w[review])
    expect(steps.second.when_files_changed).to include("**/*.rb", "test/**/*.rb", "Rakefile")
    expect(steps.second.metadata["grader_mode"]).to eq("focused")
    expect(steps.second.metadata.dig("filter_capabilities", "changed_files")).to be(true)

    expect(steps.third.phases).to eq(%w[ci])
    expect(steps.third.metadata["grader_mode"]).to eq("ci")
    expect(steps.third.metadata.dig("filter_capabilities", "ci")).to be(true)
  end

  it "synthesizes mode-aware display names by default" do
    steps = described_class.grade_steps(config: {}, default_failures: "strict")

    expect(steps.map(&:display_name)).to eq([ "Minitest", "Minitest (focused)", "Minitest (CI)" ])
  end

  it "honors command, focused_command, paths, project scope, dependencies, and per-mode timeouts" do
    steps = described_class.grade_steps(
      config: {
        "command" => "bundle exec rake test:units",
        "focused_command" => "bundle exec ruby -Itest $(cat .syrus/minitest-focused-files)",
        "paths" => [ "test/models", "test/lib" ],
        "_syrus_project_path" => "plugins/example",
        "deps" => [ "//plugins/example:prepare" ],
        "timeout_minutes" => 30,
        "timeouts" => { "focused" => 5 }
      },
      default_failures: "strict"
    )

    expect(steps.first.run).to eq("bundle exec rake test:units")
    expect(steps.second.run).to include("bundle exec ruby -Itest $(cat .syrus/minitest-focused-files)")
    expect(steps.second.run).to include("plugins/example")
    expect(steps.third.run).to eq("bundle exec rake test:units")
    expect(steps.map(&:deps)).to eq([ [ "//plugins/example:prepare" ], [ "//plugins/example:prepare" ], [ "//plugins/example:prepare" ] ])
    expect(steps.map(&:timeout_minutes)).to eq([ 30, 5, 30 ])
  end

  it "advertises JUnit output only when configured" do
    steps = described_class.grade_steps(
      config: {
        "_syrus_project_path" => "plugins/example",
        "junit_output" => true,
        "focused_junit_output" => ".syrus/minitest-focused.xml"
      },
      default_failures: "strict"
    )

    expect(steps.first.junit_output).to eq(".syrus/grade-output/plugins-example-minitest-junit.xml")
    expect(steps.first.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/grade-output/plugins-example-minitest-junit.xml", "format" => "junit" }
    ])
    expect(steps.first.metadata.dig("filter_capabilities", "failed_cases")).to be(true)
    expect(steps.second.junit_output).to eq(".syrus/minitest-focused.xml")
    expect(steps.second.metadata["result_outputs"]).to eq([
      { "artifact" => ".syrus/minitest-focused.xml", "format" => "junit" }
    ])
  end

  it "uses project-local Rails, Rake, and Ruby paths for nested auto commands" do
    steps = described_class.grade_steps(
      config: { "_syrus_project_path" => "plugins/example" },
      default_failures: "strict"
    )

    expect(steps.first.run).to include("[ -x plugins/example/bin/rails ]")
    expect(steps.first.run).to include("[ -f plugins/example/config/database.yml ]")
    expect(steps.first.run).to include("plugins/example/bin/rails db:test:prepare")
    expect(steps.first.run).to include("plugins/example/bin/rails test plugins/example/test")
    expect(steps.first.run).to include("[ -f plugins/example/Rakefile ]")
    expect(steps.first.run).to include("cd plugins/example && bundle exec rake test")
    expect(steps.first.run).to include("bundle exec ruby -Iplugins/example/test plugins/example/test")
    expect(steps.second.run).to include("plugins/example/bin/rails test $(cat .syrus/minitest-focused-files)")
    expect(steps.second.run).to include("bundle exec ruby -Iplugins/example/test $(cat .syrus/minitest-focused-files)")
  end

  it "can restrict generated graders by phase" do
    steps = described_class.grade_steps(
      config: { "phases" => [ "review", "landing" ] },
      default_failures: "strict"
    )

    expect(steps.map { |step| [ step.name, step.phases ] }).to eq([
      [ "minitest", %w[landing] ],
      [ "minitest-focused", %w[review] ],
      [ "minitest-ci", [] ]
    ])
  end

  it "rejects invalid timeout values during typed grader expansion" do
    expect {
      described_class.grade_steps(config: { "timeout_minutes" => "nope" }, default_failures: "strict")
    }.to raise_error(ArgumentError, "timeout_minutes must be a positive integer")
  end

  it "expands from a type: minitest .syrus.yml declaration" do
    allow(Syrus::PluginRegistry).to receive(:providers_for).with(:grader_type).and_return([ described_class ])

    config = SyrusYml.new(<<~YAML).parse
      grade:
        failures: allow_inherited
        steps:
          - type: minitest
            name: ruby-tests
            paths: [test/models]
    YAML

    expect(config.grade.steps.map(&:name)).to eq(%w[ruby-tests ruby-tests-focused ruby-tests-ci])
    expect(config.grade.steps.first.run).to include("bin/rails test test/models")
    expect(config.grade.steps.first.failures).to eq("allow_inherited")
    expect(config.grade.steps.first.metadata).to include(
      "grader_type" => "minitest",
      "grader_framework" => "minitest"
    )
  end

  it "generates a focused selector that returns changed Minitest files only" do
    Dir.mktmpdir do |dir|
      run_git = ->(*args) { Open3.capture3("git", "-C", dir, *args) }
      run_git.call("init", "-q", "-b", "main")
      run_git.call("config", "user.email", "test@example.com")
      run_git.call("config", "user.name", "Test")
      run_git.call("config", "commit.gpgsign", "false")
      FileUtils.mkdir_p(File.join(dir, "test/models"))
      File.write(File.join(dir, "test/models/widget_test.rb"), "require 'minitest/autorun'\n")
      File.write(File.join(dir, "test/models/ignored_helper.rb"), "# helper\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "base")
      run_git.call("checkout", "-q", "-b", "feature")
      File.write(File.join(dir, "test/models/widget_test.rb"), "require 'minitest/autorun'\nclass WidgetTest < Minitest::Test; end\n")
      File.write(File.join(dir, "test/models/ignored_helper.rb"), "# changed helper\n")
      run_git.call("add", "-A")
      run_git.call("commit", "-q", "-m", "feature")

      command = described_class.grade_steps(config: {}, default_failures: "strict").second.run
      script_arg = command.match(/ruby -e (?<script>.+?) > \.syrus\/minitest-focused-files/m)[:script]
      selector = "ruby -e #{script_arg}"

      stdout, stderr, status = Open3.capture3("bash", "-c", selector, chdir: dir)

      expect(status).to be_success, "expected the focused-file selector to run without a shell/ruby syntax error, got:\n#{stderr}"
      expect(stdout.lines.map(&:strip)).to eq([ "test/models/widget_test.rb" ])
    end
  end

  it "embeds a focused-file selector script that survives shell parsing as valid Ruby" do
    focused_step = described_class.grade_steps(config: {}, default_failures: "strict").second
    script_arg = focused_step.run.match(/ruby -e (?<script>.+?) > \.syrus\/minitest-focused-files/m)[:script]
    script = Shellwords.split(script_arg).sole

    expect { RubyVM::InstructionSequence.compile(script) }.not_to raise_error
  end
end
