# frozen_string_literal: true

require "fileutils"
require "open3"
require "spec_helper"
require "tmpdir"

RSpec.describe "bin/check-migration-collisions", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-migration-collisions") }

  def write_file(dir, relative_path, content = "")
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def run_check(dir, *args)
    Open3.capture3("ruby", script, *args, chdir: dir)
  end

  def git!(dir, *args)
    _stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  it "fails all-tree mode for duplicate versions within the primary namespace" do
    Dir.mktmpdir("migration-collisions") do |dir|
      write_file(dir, "db/migrate/20260830120000_create_widgets.rb")
      write_file(dir, "plugins/design_docs/db/migrate/20260830120000_create_design_widgets.rb")

      stdout, stderr, status = run_check(dir, "--all")

      expect(status.exitstatus).to eq(1)
      expect(stderr).to be_empty
      expect(stdout).to include("[migration-collisions] duplicate migration timestamp(s) found")
      expect(stdout).to include("primary/20260830120000")
      expect(stdout).to include("db/migrate/20260830120000_create_widgets.rb")
      expect(stdout).to include("plugins/design_docs/db/migrate/20260830120000_create_design_widgets.rb")
    end
  end

  it "allows matching versions across separate database namespaces" do
    Dir.mktmpdir("migration-collisions") do |dir|
      write_file(dir, "db/migrate/20260830120000_create_test_identities.rb")
      write_file(dir, "db/search_migrate/20260830120000_create_test_identity_search_tables.rb")

      stdout, stderr, status = run_check(dir, "--all")

      expect(status).to be_success, stderr
      expect(stdout).to include("[migration-collisions] all migration timestamps are unique within their namespaces")
    end
  end

  it "fails all-tree mode for duplicate versions inside an auxiliary namespace" do
    Dir.mktmpdir("migration-collisions") do |dir|
      write_file(dir, "db/search_migrate/20260830120000_create_search_widgets.rb")
      write_file(dir, "db/search_migrate/20260830120000_create_search_gadgets.rb")

      stdout, _stderr, status = run_check(dir, "--all")

      expect(status.exitstatus).to eq(1)
      expect(stdout).to include("search_migrate/20260830120000")
      expect(stdout).to include("db/search_migrate/20260830120000_create_search_widgets.rb")
      expect(stdout).to include("db/search_migrate/20260830120000_create_search_gadgets.rb")
    end
  end

  it "fails branch mode when a new migration collides with default branch in the same namespace" do
    Dir.mktmpdir("migration-collisions") do |dir|
      git!(dir, "init", "-q", "-b", "main")
      git!(dir, "config", "user.email", "test@example.com")
      git!(dir, "config", "user.name", "Test")
      git!(dir, "config", "commit.gpgsign", "false")
      write_file(dir, "db/migrate/20260830120000_create_widgets.rb")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-q", "-m", "base")

      git!(dir, "checkout", "-q", "-b", "feature")
      write_file(dir, "plugins/design_docs/db/migrate/20260830120000_create_design_widgets.rb")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-q", "-m", "feature")

      stdout, stderr, status = run_check(dir)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to be_empty
      expect(stdout).to include("migration timestamp(s) already exist on main")
      expect(stdout).to include("primary/20260830120000")
    end
  end
end
