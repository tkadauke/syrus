require "rails_helper"

RSpec.describe SyrusRails::MigrationParser do
  let(:schema_rb) { <<~RUBY }
    ActiveRecord::Schema[8.1].define(version: 2024_01_01_000000) do
      create_table "users", force: :cascade do |t|
        t.string "email", null: false
        t.integer "age"
      end
    end
  RUBY

  def parse(migration_content, file_name: "20240101000000_migration.rb")
    described_class.new(migration_content, schema_content: schema_rb, file_name: file_name).parse
  end

  # Regression: before/after used to be a hash of every schema table (e.g.
  # result[:before]["users"]) instead of a single { table_name:, columns: }
  # object. The frontend renderer reads before.columns directly, so any
  # payload in the old shape crashed with "undefined is not an object
  # (evaluating 'n.map')" the moment a migration artifact was viewed.
  it "always returns a single-table before/after shape, not a table-name-keyed hash" do
    result = parse(<<~RUBY)
      class AddNameToUsers < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :name, :string
        end
      end
    RUBY

    expect(result[:before]).to include(:table_name, :columns)
    expect(result[:after]).to include(:table_name, :columns)
    expect(result[:before][:columns]).to be_an(Array)
    expect(result[:after][:columns]).to be_an(Array)
  end

  it "extracts the migration class name" do
    result = parse(<<~RUBY)
      class AddNameToUsers < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :name, :string
        end
      end
    RUBY

    expect(result[:migration_name]).to eq("AddNameToUsers")
  end

  it "falls back to the file name when no class definition is found" do
    result = parse("add_column :users, :name, :string", file_name: "20240101000000_add_name_to_users.rb")

    expect(result[:migration_name]).to eq("add_name_to_users")
  end

  it "shows a removed column present before and absent after" do
    result = parse(<<~RUBY)
      class RemoveAgeFromUsers < ActiveRecord::Migration[8.1]
        def change
          remove_column :users, :age
        end
      end
    RUBY

    before_names = result[:before][:columns].map { |c| c[:name] }
    after_names  = result[:after][:columns].map { |c| c[:name] }
    expect(before_names).to include("age")
    expect(after_names).not_to include("age")
    expect(result[:changes]).to eq([{ type: "removed", column: { name: "age", type: "unknown" } }])
  end

  it "renames a column between before and after" do
    result = parse(<<~RUBY)
      class RenameEmailOnUsers < ActiveRecord::Migration[8.1]
        def change
          rename_column :users, :email, :email_address
        end
      end
    RUBY

    before_names = result[:before][:columns].map { |c| c[:name] }
    after_names  = result[:after][:columns].map { |c| c[:name] }
    expect(before_names).to include("email")
    expect(after_names).to include("email_address")
    expect(result[:changes]).to eq([{ type: "modified", column: { name: "email_address", type: "unknown" } }])
  end

  it "changes a column type between before and after" do
    result = parse(<<~RUBY)
      class ChangeAgeOnUsers < ActiveRecord::Migration[8.1]
        def change
          change_column :users, :age, :bigint
        end
      end
    RUBY

    after_col = result[:after][:columns].find { |c| c[:name] == "age" }
    expect(after_col[:type]).to eq("bigint")
    expect(result[:changes]).to eq([{ type: "modified", column: { name: "age", type: "bigint" } }])
  end

  it "shows an empty table before create_table and populated after" do
    result = parse(<<~RUBY)
      class CreatePosts < ActiveRecord::Migration[8.1]
        def change
          create_table :posts do |t|
            t.string :title
          end
        end
      end
    RUBY

    expect(result[:before][:columns]).to eq([])
    expect(result[:after][:table_name]).to eq("posts")
    expect(result[:changes]).to eq([])
  end

  it "shows a populated table before drop_table and empty after" do
    result = parse(<<~RUBY)
      class DropUsers < ActiveRecord::Migration[8.1]
        def change
          drop_table :users
        end
      end
    RUBY

    expect(result[:before][:table_name]).to eq("users")
    expect(result[:before][:columns].map { |c| c[:name] }).to include("email", "age")
    expect(result[:after][:columns]).to eq([])
  end

  it "returns an empty single-table shape when no recognized migration DSL is found" do
    result = parse("# no-op migration")

    expect(result[:before]).to eq(table_name: "", columns: [])
    expect(result[:after]).to eq(table_name: "", columns: [])
    expect(result[:changes]).to eq([])
  end

  # Regression: Syrus's own idempotent-migration convention (CLAUDE.md) writes
  # separate up/down methods with inline column_exists? guards instead of a
  # single `change` method. A naive line scan matched add_column in `up` AND
  # the mirrored remove_column in `down`, recording the column as both added
  # and removed. Those changes cancelled out, leaving before/after identical
  # (both missing the new column) and a nonsensical changes list showing the
  # same column as "added" and "removed" -- the "card renders as if this is
  # the before, not the after" bug.
  it "only counts the up-method change for an idempotent up/down migration, ignoring the mirrored down guard" do
    result = parse(<<~RUBY)
      class AddNameToUsers < ActiveRecord::Migration[8.1]
        def up
          add_column :users, :name, :string unless column_exists?(:users, :name)
        end

        def down
          remove_column :users, :name if column_exists?(:users, :name)
        end
      end
    RUBY

    before_names = result[:before][:columns].map { |c| c[:name] }
    after_names  = result[:after][:columns].map { |c| c[:name] }
    expect(before_names).not_to include("name")
    expect(after_names).to include("name")
    expect(result[:changes]).to eq([{ type: "added", column: { name: "name", type: "string" } }])
  end

  # Regression: db/schema.rb reflects the fully-migrated state, so a migration
  # already applied to it has its added column present there too. The old
  # code unconditionally appended the added column a second time, so `after`
  # listed it twice.
  it "does not duplicate an added column that is already present in the current schema" do
    schema_with_name = <<~RUBY
      ActiveRecord::Schema[8.1].define(version: 2024_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.integer "age"
          t.string "name"
        end
      end
    RUBY
    result = described_class.new(<<~RUBY, schema_content: schema_with_name).parse
      class AddNameToUsers < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :name, :string
        end
      end
    RUBY

    after_names = result[:after][:columns].map { |c| c[:name] }
    expect(after_names.count("name")).to eq(1)
    expect(result[:before][:columns].map { |c| c[:name] }).not_to include("name")
  end
end
