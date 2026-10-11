# frozen_string_literal: true

require "open3"
require "tmpdir"
require "fileutils"
require "spec_helper"

RSpec.describe "bin/check-spa-entry-budget" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-spa-entry-budget") }

  def write_build_file(dir, name, content)
    path = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run_script(build_dir)
    Open3.capture3({ "SPA_BUILD_DIR" => build_dir }, script)
  end

  it "accepts split SPA output with digested dynamic CSS assets" do
    Dir.mktmpdir do |dir|
      write_build_file(dir, "spa.js", "x" * 100)
      write_build_file(dir, "spa-preload-helper-abc123.digested.js", "/assets/")
      write_build_file(dir, "spa-SlugHoverCard-def456.digested.css", "body{}")

      _stdout, stderr, status = run_script(dir)

      expect(status).to be_success, stderr
    end
  end

  it "rejects bare dynamic CSS assets that Propshaft will not serve at Vite's preload URL" do
    Dir.mktmpdir do |dir|
      write_build_file(dir, "spa.js", "x" * 100)
      write_build_file(dir, "spa-preload-helper-abc123.digested.js", "/assets/")
      write_build_file(dir, "spa-SlugHoverCard.css", "body{}")

      _stdout, stderr, status = run_script(dir)

      expect(status).not_to be_success
      expect(stderr).to include("SPA CSS chunks must include a hash and .digested marker")
      expect(stderr).to include("spa-SlugHoverCard.css")
    end
  end
end
