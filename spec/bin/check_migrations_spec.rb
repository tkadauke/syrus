# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
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

  def run_check(*args, env: {}, chdir: @dir)
    Open3.capture3(
      { "SYRUS_MIGRATION_LINT_ROOT" => @dir }.merge(env),
      RbConfig.ruby,
      script,
      *args,
      chdir: chdir,
      unsetenv_others: true
    )
  end

  def git!(*args)
    _stdout, stderr, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?
  end

  def git_output(*args)
    stdout, stderr, status = Open3.capture3("git", "-C", @dir, *args)
    raise "git #{args.join(' ')} failed: #{stderr}" unless status.success?

    stdout.strip
  end

  # Rails' own `if_not_exists: true` is idempotent; only the explicit
  # `unless index_exists?` spelling used to count, which failed a merge train
  # on a migration that was already safe to retry.
  it "accepts if_not_exists as an idempotency guard, also across continuation lines" do
    write_migration("db/migrate/20261119120000_add_widget_indexes.rb", <<~RUBY)
      class AddWidgetIndexes < ActiveRecord::Migration[8.1]
        def change
          add_index :widgets, :name, unique: true, if_not_exists: true
          add_index :widgets, :kind,
            name: "idx_widgets_kind",
            if_not_exists: true
          add_column :widgets, :note, :string, if_not_exists: true
          remove_column :widgets, :legacy, :string, if_exists: true
        end
      end
    RUBY

    stdout, stderr, status = run_check("--all")

    expect(status).to be_success, stderr
    expect(stdout).to include("no offenses")
  end

  it "still rejects a bare add_index" do
    write_migration("db/migrate/20261119120000_add_widget_index.rb", <<~RUBY)
      class AddWidgetIndex < ActiveRecord::Migration[8.1]
        def change
          add_index :widgets, :name, unique: true
        end
      end
    RUBY

    _stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("[non_idempotent_add_index] db/migrate/20261119120000_add_widget_index.rb:3")
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

  # Regression: a plugin migration renamed coverage_snapshots in place and
  # Runs still on the previous release failed with "Table doesn't exist".
  it "rejects in-place table and column renames after the rolling-deploy policy" do
    write_migration("plugins/widgets/db/migrate/20261125120000_rename_widgets.rb", <<~RUBY)
      class RenameWidgets < ActiveRecord::Migration[8.0]
        def change
          rename_table :widgets, :plugin_widgets
          rename_column :plugin_widgets, :name, :label
        end
      end
    RUBY

    stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to be_empty
    expect(stderr).to include("[rolling_deploy_rename] plugins/widgets/db/migrate/20261125120000_rename_widgets.rb:3")
    expect(stderr).to include("[rolling_deploy_rename] plugins/widgets/db/migrate/20261125120000_rename_widgets.rb:4")
  end

  it "leaves renames that predate the rolling-deploy policy alone" do
    write_migration("db/migrate/20261123120000_rename_gadgets.rb", <<~RUBY)
      class RenameGadgets < ActiveRecord::Migration[8.0]
        def up
          rename_table :gadgets, :old_gadgets if table_exists?(:gadgets)
        end
      end
    RUBY

    _stdout, stderr, _status = run_check("--all")

    expect(stderr).not_to include("rolling_deploy_rename")
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

  it "rejects post-policy database foreign keys in plugin migrations" do
    write_migration("plugins/design_docs/db/migrate/20260830120400_create_design_widgets.rb", <<~RUBY)
      class CreateDesignWidgets < ActiveRecord::Migration[8.0]
        def change
          create_table :design_widgets do |t|
            t.references :repo, foreign_key: true
          end
        end
      end
    RUBY

    _stdout, stderr, status = run_check("--all")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include(
      "[database_foreign_key] plugins/design_docs/db/migrate/20260830120400_create_design_widgets.rb:4"
    )
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

  it "uses the single fetched stacked base in a detached immutable checkout" do
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
    git!("commit", "-q", "-m", "stacked base")
    base_sha = git_output("rev-parse", "HEAD")
    File.write(File.join(@dir, "README.md"), "feature\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "feature")
    git!("update-ref", "refs/remotes/origin/syrus/parent", base_sha)
    git!("checkout", "-q", "--detach", "HEAD")
    git!("branch", "-D", "main")

    stdout, stderr, status = run_check

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-migrations] ok (0 changed files")
  end

  # A grader checkout can carry a stale origin/main alongside the Job's real
  # base. Diffing against it turned migrations that landed on main after it
  # into "this branch's changes", so a Job failed migration-lint on every
  # retry for an upstream file no repair could touch.
  it "lints against the grader's SYRUS_BASE_REF rather than a stale origin/main" do
    git!("init", "-q", "-b", "main")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test")
    git!("config", "commit.gpgsign", "false")
    File.write(File.join(@dir, "README.md"), "base\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "old main")
    git!("update-ref", "refs/remotes/origin/main", git_output("rev-parse", "HEAD"))
    write_migration("db/migrate/20261119131053_upstream_bad_fk.rb", <<~RUBY)
      class UpstreamBadFk < ActiveRecord::Migration[8.0]
        def change
          add_foreign_key :widgets, :repositories
        end
      end
    RUBY
    git!("add", "-A")
    git!("commit", "-q", "-m", "upstream migration the Job is stacked on")
    git!("update-ref", "refs/remotes/origin/syrus/parent", git_output("rev-parse", "HEAD"))
    File.write(File.join(@dir, "README.md"), "feature\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "feature")
    git!("checkout", "-q", "--detach", "HEAD")

    stdout, stderr, status = run_check(env: { "SYRUS_BASE_REF" => "origin/syrus/parent" })

    expect(status).to be_success, stderr
    expect(stdout).to include("[check-migrations] ok (0 changed files")
  end

  it "fails safely instead of scanning every migration when no diff base exists" do
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
    git!("commit", "-q", "-m", "orphaned checkout")
    git!("checkout", "-q", "--detach", "HEAD")
    git!("branch", "-D", "main")

    _stdout, stderr, status = run_check

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("could not resolve a unique diff base")
    expect(stderr).not_to include("offense(s)")
  end

  it "fails safely when multiple possible stacked bases exist" do
    git!("init", "-q", "-b", "feature")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test")
    git!("config", "commit.gpgsign", "false")
    File.write(File.join(@dir, "README.md"), "base\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "base")
    base_sha = git_output("rev-parse", "HEAD")
    git!("update-ref", "refs/remotes/origin/first-parent", base_sha)
    git!("update-ref", "refs/remotes/upstream/second-parent", base_sha)

    _stdout, stderr, status = run_check

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("multiple are available: origin/first-parent, upstream/second-parent")
    expect(stderr).not_to include("offense(s)")
  end

  it "honors an explicit base ref and runs Git from the configured repository root" do
    git!("init", "-q", "-b", "feature")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test")
    git!("config", "commit.gpgsign", "false")
    File.write(File.join(@dir, "README.md"), "base\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "base")
    base_sha = git_output("rev-parse", "HEAD")
    write_migration("db/migrate/20260830120600_add_widget_fk.rb", <<~RUBY)
      class AddWidgetFk < ActiveRecord::Migration[8.0]
        def change
          add_foreign_key :widgets, :repositories
        end
      end
    RUBY
    git!("add", "-A")
    git!("commit", "-q", "-m", "feature")
    nested_dir = File.join(@dir, "tmp", "nested")
    FileUtils.mkdir_p(nested_dir)

    _stdout, stderr, status = run_check(
      env: { "SYRUS_MIGRATION_LINT_BASE_REF" => base_sha },
      chdir: nested_dir
    )

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("[database_foreign_key] db/migrate/20260830120600_add_widget_fk.rb:3")
  end

  it "lints changed plugin migrations in review scope" do
    git!("init", "-q", "-b", "main")
    git!("config", "user.email", "test@example.com")
    git!("config", "user.name", "Test")
    git!("config", "commit.gpgsign", "false")
    File.write(File.join(@dir, "README.md"), "base\n")
    git!("add", "-A")
    git!("commit", "-q", "-m", "base")
    git!("checkout", "-q", "-b", "feature")
    write_migration("plugins/design_docs/db/migrate/20260830120500_add_design_widget_owner.rb", <<~RUBY)
      class AddDesignWidgetOwner < ActiveRecord::Migration[8.0]
        def change
          add_reference :design_widgets, :owner, foreign_key: { to_table: :users } unless column_exists?(:design_widgets, :owner_id)
        end
      end
    RUBY
    git!("add", "-A")
    git!("commit", "-q", "-m", "feature")

    _stdout, stderr, status = run_check

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include(
      "[database_foreign_key] plugins/design_docs/db/migrate/20260830120500_add_design_widget_owner.rb:3"
    )
  end
end
