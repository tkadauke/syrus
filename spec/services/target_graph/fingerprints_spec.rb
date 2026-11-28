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

  it "invalidates input fingerprints when a source file is directly inside the pattern directory" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: npm test
          when_files_changed: ["src/**/*.ts"]
    YAML
    write("src/index.ts", "export const value = 1\n")

    first = fingerprints_for("//:grade/tests")
    write("src/index.ts", "export const value = 2\n")

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

  it "invalidates command fingerprints when execution capability requirements change" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/test
          capabilities:
            os: linux
    YAML
    first = fingerprints_for("//:grade/tests")

    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/test
          capabilities:
            os: macos
    YAML

    expect(fingerprints_for("//:grade/tests").command_fingerprint).not_to eq(first.command_fingerprint)
  end

  it "invalidates environment fingerprints when worker capabilities change" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: tests
          run: bin/test
    YAML
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata)
      .and_return(worker_environment("linux"), worker_environment("macos"))

    first = fingerprints_for("//:grade/tests")

    expect(fingerprints_for("//:grade/tests").environment_fingerprint).not_to eq(first.environment_fingerprint)
  end

  it "uses the target execution capabilities in worker environment metadata" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: backend
          run: bin/test
          capabilities:
            os: linux
    YAML
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata)
      .and_return(worker_environment("macos"))

    fingerprints = fingerprints_for("//:grade/backend")

    expect(fingerprints.metadata.dig("worker_environment", "capabilities")).to eq("os" => [ "linux" ])
  end

  it "uses default Linux execution capabilities for unannotated grader targets" do
    write(".syrus.yml", <<~YAML)
      grade:
        - name: backend
          run: bin/test
    YAML
    allow(WorkerCapabilities).to receive(:environment_fingerprint_metadata)
      .and_return(worker_environment("macos"))

    fingerprints = fingerprints_for("//:grade/backend")

    expect(fingerprints.metadata.dig("worker_environment", "capabilities")).to eq("os" => [ "linux" ])
  end

  describe "shared file digests" do
    before do
      write(".syrus.yml", <<~YAML)
        grade:
          - name: everything
            run: bin/check
          - name: models
            run: bin/rspec
            when_files_changed: ["app/**/*.rb"]
          - name: frontend
            run: npm test
            when_files_changed: ["src/**/*.ts"]
      YAML
      write("app/models/user.rb", "class User; end\n")
      write("app/models/team.rb", "class Team; end\n")
      write("src/index.ts", "export const value = 1\n")
    end

    let(:labels) { %w[//:grade/everything //:grade/models //:grade/frontend] }

    it "produces byte-identical fingerprints to unshared computation" do
      graph = TargetGraph::Compiler.compile(@dir)
      digests = TargetGraph::FileDigests.new(@dir)

      labels.each do |label|
        shared = described_class.for_target(workspace_path: @dir, graph: graph, label: TargetGraph::Label.parse(label), file_digests: digests)
        unshared = described_class.for_target(workspace_path: @dir, graph: graph, label: TargetGraph::Label.parse(label))

        expect(shared.to_h).to eq(unshared.to_h)
      end
    end

    # Regression: a fan-out fingerprinting every target hashed the whole tree
    # once per target (twice, counting the metadata counts), which was three
    # to four minutes of each production fan-out.
    it "hashes each file once across every target that shares the digests" do
      graph = TargetGraph::Compiler.compile(@dir)
      digests = TargetGraph::FileDigests.new(@dir)
      hashed = Hash.new(0)
      allow(Digest::SHA256).to receive(:file).and_wrap_original do |original, path|
        hashed[Pathname.new(path).relative_path_from(@dir).to_s] += 1
        original.call(path)
      end

      labels.each do |label|
        described_class.for_target(workspace_path: @dir, graph: graph, label: TargetGraph::Label.parse(label), file_digests: digests)
      end

      expect(hashed.keys).to include("app/models/user.rb", "src/index.ts", ".syrus.yml")
      expect(hashed.values).to all(eq(1))
    end

    it "hashes a target's source files once even without shared digests" do
      graph = TargetGraph::Compiler.compile(@dir)
      allow(Digest::SHA256).to receive(:file).and_call_original

      described_class.for_target(workspace_path: @dir, graph: graph, label: TargetGraph::Label.parse("//:grade/models"))

      expect(Digest::SHA256).to have_received(:file).with(@dir.join("app/models/user.rb")).once
    end

    it "refuses digests recorded for a different workspace" do
      Dir.mktmpdir("syrus-other-workspace") do |other|
        expect do
          described_class.new(workspace_path: @dir, graph: TargetGraph::Compiler.compile(@dir), file_digests: TargetGraph::FileDigests.new(other))
        end.to raise_error(ArgumentError, /cannot fingerprint/)
      end
    end
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

  def worker_environment(os)
    {
      "capabilities" => { "os" => [ os ] },
      "runtime" => { "ruby_platform" => "#{os}-ruby" },
      "tool_versions" => { "ruby" => "ruby 3.4.10" }
    }
  end
end
