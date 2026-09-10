require "rails_helper"
require "tmpdir"

RSpec.describe TargetGraph::Fingerprints do
  around do |example|
    Dir.mktmpdir("syrus-target-fingerprints") do |dir|
      @dir = Pathname.new(dir)
      example.run
    end
  end

  it "invalidates input fingerprints when declared source files change" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          when_files_changed: ["app/**/*.rb"]
    YAML
    write("app/models/user.rb", "class User; end\n")

    first = fingerprints_for("//:grade/tests")
    write("app/models/user.rb", "class User\n  def active? = true\nend\n")

    expect(fingerprints_for("//:grade/tests").input_fingerprint).not_to eq(first.input_fingerprint)
  end

  it "invalidates input fingerprints when dependency target sources change" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: app
          kind: library
          sources: ["app/**/*.rb"]
      grade:
        - name: tests
          run: bin/rspec
          when_files_changed: ["spec/**/*.rb"]
          deps: [":app"]
    YAML
    write("app/models/user.rb", "class User; end\n")
    write("spec/models/user_spec.rb", "RSpec.describe User\n")

    first = fingerprints_for("//:grade/tests")
    write("app/models/user.rb", "class User\n  def active? = true\nend\n")

    expect(fingerprints_for("//:grade/tests").input_fingerprint).not_to eq(first.input_fingerprint)
  end

  it "invalidates command fingerprints when command text or execution config changes" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          phases: [review, landing]
          timeout_minutes: 15
    YAML
    first = fingerprints_for("//:grade/tests")

    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/rspec spec/models/user_spec.rb
          phases: [review]
          required: false
          timeout_minutes: 30
    YAML

    expect(fingerprints_for("//:grade/tests").command_fingerprint).not_to eq(first.command_fingerprint)
  end

  it "invalidates command fingerprints when dependency target config changes" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: schema
          kind: generator
          command: bin/rails db:schema:dump
          sources: ["db/migrate/**/*.rb"]
      grade:
        - name: tests
          run: bin/rspec
          deps: [":schema"]
    YAML
    first = fingerprints_for("//:grade/tests")

    write(".syrus.yml", <<~YAML)
      targets:
        - name: schema
          kind: generator
          command: bin/rails db:prepare
          sources: ["db/migrate/**/*.rb"]
      grade:
        - name: tests
          run: bin/rspec
          deps: [":schema"]
    YAML

    expect(fingerprints_for("//:grade/tests").command_fingerprint).not_to eq(first.command_fingerprint)
  end

  it "invalidates input fingerprints when the owning .syrus.yml changes even if commands are unchanged" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          description: Before
    YAML
    first = fingerprints_for("//:grade/tests")

    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/rspec
          description: After
    YAML

    expect(fingerprints_for("//:grade/tests").input_fingerprint).not_to eq(first.input_fingerprint)
  end

  it "invalidates environment fingerprints when prepare or toolchain inputs change" do
    write(".syrus.yml", <<~YAML)
      targets:
        - name: deps
          kind: prepare
          run: bundle install
      grade:
        - name: tests
          run: bin/rspec
          deps: [":deps"]
    YAML
    write("Gemfile.lock", "GEM\n")
    first = fingerprints_for("//:grade/tests")

    write("Gemfile.lock", "GEM\n  remote: https://rubygems.org/\n")

    expect(fingerprints_for("//:grade/tests").environment_fingerprint).not_to eq(first.environment_fingerprint)
  end

  def fingerprints_for(label)
    described_class.for_target(
      workspace_path: @dir,
      graph: TargetGraph::Compiler.compile(@dir),
      label: TargetGraph::Label.parse(label)
    )
  end

  def write(relative_path, contents)
    path = @dir.join(relative_path)
    FileUtils.mkdir_p(path.dirname)
    path.write(contents)
  end
end
