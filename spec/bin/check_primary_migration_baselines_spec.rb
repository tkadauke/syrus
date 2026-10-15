# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "spec_helper"
require "tmpdir"

RSpec.describe "bin/check-primary-migration-baselines", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-primary-migration-baselines") }

  def write_file(dir, relative_path, content = "")
    path = File.join(dir, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    FileUtils.chmod("+x", path) if relative_path == "bin/rails"
  end

  def git!(dir, *args)
    _stdout, stderr, status = Open3.capture3("git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  it "runs a backdated migration that is absent from the tagged baseline" do
    Dir.mktmpdir("primary-migration-baselines") do |dir|
      write_file(dir, "bin/check-primary-migration-baselines", File.read(script))
      write_file(dir, "Gemfile")
      write_file(dir, "db/schema.rb", "ActiveRecord::Schema.define(version: 2026_10_10_000000)\n")
      write_file(dir, "db/migrate/20261001000000_create_existing.rb")
      write_file(dir, "bin/rails", <<~'RUBY')
        #!/usr/bin/env ruby
        require "json"

        data_root = ENV.fetch("SYRUS_DATA_ROOT")
        applied_path = File.join(data_root, "applied.json")
        applied = File.exist?(applied_path) ? JSON.parse(File.read(applied_path)) : []
        versions = Dir[File.expand_path("../db/migrate/*.rb", __dir__)].map { |path| File.basename(path)[/\A(\d+)_/, 1] }

        case ARGV.join(" ")
        when /db:create/
          nil
        when /db:migrate:primary/
          pending = versions - applied
          File.open(ENV.fetch("MIGRATION_EXECUTION_LOG"), "a") { |file| pending.each { |version| file.puts "#{File.basename(data_root)} #{version}" } }
          applied |= pending
        when /runner load /
          applied |= versions.select { |version| version <= "20261010000000" }
        when /runner/
          applied &= JSON.parse(ENV.fetch("SYRUS_BASELINE_MIGRATION_VERSIONS"))
        else
          abort "unexpected command: #{ARGV.join(' ')}"
        end

        File.write(applied_path, JSON.generate(applied))
      RUBY

      git!(dir, "init", "-q", "-b", "main")
      git!(dir, "config", "user.email", "test@example.com")
      git!(dir, "config", "user.name", "Test")
      git!(dir, "config", "commit.gpgsign", "false")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-q", "-m", "baseline")
      git!(dir, "tag", "production")

      write_file(dir, "db/migrate/20261008000000_create_backdated.rb")
      execution_log = File.join(dir, "executed.log")
      stdout, stderr, status = Open3.capture3(
        {
          "HOME" => ENV.fetch("HOME"),
          "MIGRATION_BASELINE_TAGS" => "production",
          "MIGRATION_EXECUTION_LOG" => execution_log,
          "PATH" => ENV.fetch("PATH")
        },
        RbConfig.ruby,
        File.join(dir, "bin/check-primary-migration-baselines"),
        chdir: dir,
        unsetenv_others: true
      )

      expect(status).to be_success, stderr
      expect(stdout).to include("[migration-baselines] ok")
      tagged_executions = File.readlines(execution_log, chomp: true).grep(/syrus-primary-migrate-production-/)
      expect(tagged_executions.map { |line| line.split.last }).to eq([ "20261008000000" ])
    end
  end
end
