# frozen_string_literal: true

require "fileutils"
require "open3"
require "spec_helper"
require "tmpdir"

RSpec.describe "bin/check-migrations", :ci_only do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "bin/check-migrations") }

  around do |example|
    Dir.mktmpdir("check-migrations") do |dir|
      @dir = dir
      example.run
    end
  end

  def write_migration(path, body)
    full_path = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, body)
  end

  def run_check(*args)
    Open3.capture3(
      { "SYRUS_MIGRATION_LINT_ROOT" => @dir },
      "ruby",
      script,
      *args,
      chdir: @dir,
      unsetenv_others: true
    )
  end

  def git!(*args)
    _stdout, stderr, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  it "rejects post-policy references with foreign_key true without booting Rails" do
    write_migration("db/migrate/20260830120000_create_widgets.rb", <<~RUBY)
      class CreateWidgets < ActiveRecord::Migration[8.0]
        def change
          create_table :widgets do |t|
            t.references :repo, foreign_key: true
          end
        end
      end
    RUBY

    stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    expect(stderr).to include("[database_foreign_key] db/migrate/20260830120000_create_widgets.rb:4")
    expect(stderr).to include("Syrus intentionally disables database-level FKs")
  end

  it "rejects post-policy top-level add_foreign_key without booting Rails" do
    write_migration("db/migrate/20260830120100_add_widget_fk.rb", <<~RUBY)
      class AddWidgetFk < ActiveRecord::Migration[8.0]
        def change
          add_foreign_key :widgets, :repositories
        end
      end
    RUBY

    _stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("[database_foreign_key] db/migrate/20260830120100_add_widget_fk.rb:3")
    expect(stderr).to include("top-level `add_foreign_key`")
  end

  it "rejects post-policy foreign_key hash options without booting Rails" do
    write_migration("db/migrate/20260830120200_add_owner_to_widgets.rb", <<~RUBY)
      class AddOwnerToWidgets < ActiveRecord::Migration[8.0]
        def change
          add_reference :widgets, :owner, foreign_key: { to_table: :users } unless column_exists?(:widgets, :owner_id)
        end
      end
    RUBY

    _stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("[database_foreign_key] db/migrate/20260830120200_add_owner_to_widgets.rb:3")
    expect(stderr).to include("add an indexed bigint/reference column without a DB constraint")
  end

  it "allows historical foreign key declarations before the no-FK policy version" do
    write_migration("db/migrate/20260819010000_historical_fk.rb", <<~RUBY)
      class HistoricalFk < ActiveRecord::Migration[8.0]
        def change
          add_foreign_key :widgets, :repositories
        end
      end
    RUBY

    stdout, stderr, status = run_check("--all")

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-migrations] ok")
  end

  it "rejects integer foreign key columns in the fast lint path" do
    write_migration("db/migrate/20260830120300_add_repo_id_to_widgets.rb", <<~RUBY)
      class AddRepoIdToWidgets < ActiveRecord::Migration[8.0]
        def change
          add_column :widgets, :repo_id, :integer unless column_exists?(:widgets, :repo_id)
        end
      end
    RUBY

    _stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("[integer_foreign_key_column] db/migrate/20260830120300_add_repo_id_to_widgets.rb:3")
  end

  it "does not fail review scope for unchanged historical base-branch offenses" do
    git!("init", "-q", "-b", "main")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test")
    git!("config", "commit.gpgsign", "false")
    write_migration("db/migrate/20260830120400_existing_bad_fk.rb", <<~RUBY)
      class ExistingBadFk < ActiveRecord::Migration[8.0]
        def change
          add_foreign_key :widgets, :repositories
        end
      end
    RUBY
    git!("add", "-A")
    git!("commit", "-q", "-m", "base")
    git!("checkout", "-q", "-b", "feature")
    File.write(File.join(@dir, "README.md"), "feature\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "feature")

    stdout, stderr, status = run_check

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-migrations] ok (0 changed files")
  end
end
