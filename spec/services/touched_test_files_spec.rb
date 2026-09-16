require "rails_helper"
require "tmpdir"

RSpec.describe TouchedTestFiles do
  around do |ex|
    Dir.mktmpdir("syrus-touched-test-files") { |dir| @dir = dir; ex.run }
  end

  def sh(*args, env: {})
    ok = system(env, *args, chdir: @dir, out: File::NULL, err: File::NULL)
    raise "command failed: #{args.join(' ')}" unless ok
  end

  def init_repo
    sh("git", "init", "-q", "-b", "main")
    sh("git", "config", "user.email", "test@example.com")
    sh("git", "config", "user.name", "Test")
  end

  def write(path, content)
    full = Pathname.new(@dir).join(path)
    full.dirname.mkpath
    full.write(content)
  end

  def commit(message)
    sh("git", "add", "-A")
    sh("git", "commit", "-q", "-m", message)
  end

  def head_sha
    `git -C #{@dir} rev-parse HEAD`.strip
  end

  it "detects test files added or modified in the diff, excluding non-test and deleted files" do
    init_repo
    write("app/foo.rb", "class Foo; end\n")
    write("spec/foo_spec.rb", "RSpec.describe Foo do\nend\n")
    write("spec/bar_spec.rb", "RSpec.describe Bar do\nend\n")
    commit("base")
    base_sha = head_sha

    write("spec/foo_spec.rb", "RSpec.describe Foo do\n  it('works') {}\nend\n") # modified test
    write("spec/new_spec.rb", "RSpec.describe New do\nend\n")                   # added test
    write("app/foo.rb", "class Foo\n  def bar; end\nend\n")                     # modified, not a test
    FileUtils.rm(Pathname.new(@dir).join("spec/bar_spec.rb"))                   # deleted test
    commit("changes")

    result = described_class.call(workspace_path: @dir, base_ref: base_sha)

    expect(result).to eq(%w[spec/foo_spec.rb spec/new_spec.rb])
  end

  it "recognizes common test file conventions across languages" do
    init_repo
    write("README.md", "hello\n")
    commit("base")
    base_sha = head_sha

    write("app/frontend/Widget.test.tsx", "test('renders', () => {})\n")
    write("app/frontend/Widget.spec.ts", "it('works', () => {})\n")
    write("scripts/tool_test.go", "package main\n")
    write("scripts/test_tool.py", "def test_tool(): pass\n")
    write("scripts/build.sh", "#!/bin/sh\n")
    commit("changes")

    result = described_class.call(workspace_path: @dir, base_ref: base_sha)

    expect(result).to eq(%w[
      app/frontend/Widget.spec.ts
      app/frontend/Widget.test.tsx
      scripts/test_tool.py
      scripts/tool_test.go
    ])
  end

  it "returns no files when base_ref is blank" do
    init_repo
    write("spec/foo_spec.rb", "RSpec.describe Foo do\nend\n")
    commit("base")

    expect(described_class.call(workspace_path: @dir, base_ref: "")).to eq([])
    expect(described_class.call(workspace_path: @dir, base_ref: nil)).to eq([])
  end
end
