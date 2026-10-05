# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require "spec_helper"

RSpec.describe "bin/check-spa-entry-budget" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-spa-entry-budget") }

  def run_script(dir)
    Open3.capture3({ "SPA_BUILD_DIR" => File.join(dir, "app/assets/builds") }, "node", script, chdir: dir)
  end

  def write_asset(dir, name, content = "")
    path = File.join(dir, "app/assets/builds", name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  it "fails when a lazy JavaScript chunk references CSS that was not emitted" do
    Dir.mktmpdir do |dir|
      write_asset(dir, "spa.js", "import './spa-preload-helper-test.digested.js';")
      write_asset(dir, "spa-preload-helper-test.digested.js", "const base = '/assets/';")
      write_asset(dir, "spa-Dashboard-test.digested.js", 'const css = "spa-SlugHoverCard-test.digested.css";')

      _stdout, stderr, status = run_script(dir)

      expect(status).not_to be_success
      expect(stderr).to include("SPA lazy CSS preload references point at files that were not emitted.")
      expect(stderr).to include("spa-SlugHoverCard-test.digested.css referenced by spa-Dashboard-test.digested.js")
    end
  end

  it "fails when a lazy JavaScript chunk references non-digested CSS" do
    Dir.mktmpdir do |dir|
      write_asset(dir, "spa.js", "import './spa-preload-helper-test.digested.js';")
      write_asset(dir, "spa-preload-helper-test.digested.js", "const base = '/assets/';")
      write_asset(dir, "spa-Dashboard-test.digested.js", 'const css = "spa-SlugHoverCard.css";')
      write_asset(dir, "spa-SlugHoverCard.css", ".card {}")

      _stdout, stderr, status = run_script(dir)

      expect(status).not_to be_success
      expect(stderr).to include("SPA lazy CSS preload references must use .digested.css filenames")
      expect(stderr).to include("spa-SlugHoverCard.css referenced by spa-Dashboard-test.digested.js")
    end
  end

  it "passes when lazy CSS references use emitted digested files" do
    Dir.mktmpdir do |dir|
      write_asset(dir, "spa.js", "import './spa-preload-helper-test.digested.js';")
      write_asset(dir, "spa-preload-helper-test.digested.js", "const base = '/assets/';")
      write_asset(dir, "spa-Dashboard-test.digested.js", 'const css = "spa-SlugHoverCard-test.digested.css";')
      write_asset(dir, "spa-SlugHoverCard-test.digested.css", ".card {}")

      stdout, stderr, status = run_script(dir)

      expect(status).to be_success, "expected success, got stdout=#{stdout.inspect} stderr=#{stderr.inspect}"
      expect(stdout).to include("SPA entry bundle")
    end
  end
end
