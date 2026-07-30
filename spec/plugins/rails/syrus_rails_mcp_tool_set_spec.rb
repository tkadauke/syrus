require "rails_helper"
require "tmpdir"

RSpec.describe SyrusRails::McpToolSet do
  let(:tool_set) { described_class.new }

  describe ".tool_definitions" do
    subject(:defs) { described_class.tool_definitions }

    it "returns three tool definitions" do
      expect(defs.length).to eq(3)
    end

    it "includes read_schema, explain_migration, and list_routes" do
      names = defs.map { |d| d[:name] }
      expect(names).to contain_exactly("read_schema", "explain_migration", "list_routes")
    end

    it "every definition has a non-empty description" do
      defs.each { |d| expect(d[:description]).to be_present }
    end

    it "explain_migration requires file_path" do
      explain = defs.find { |d| d[:name] == "explain_migration" }
      expect(explain[:input_schema][:required]).to include("file_path")
    end
  end

  describe ".available_for?" do
    it "returns true for any repository" do
      expect(described_class.available_for?(double("repository"))).to be true
    end
  end

  # Helper: build a fake server_context backed by a temp workspace directory.
  # Yields the context and the workspace Pathname so each example can write fixture files.
  def with_workspace
    Dir.mktmpdir("syrus-rails-mcp") do |dir|
      ws = Pathname.new(dir)
      run_dbl = instance_double(Run, workflow: instance_double(Workflow))
      allow(WorkflowWorkspace).to receive(:path_for).and_return(ws)
      allow(SyrusMcp).to receive(:run_from_context).and_return(run_dbl)
      yield({ run_id: 1 }, ws)
    end
  end

  # ------------------------------------------------------------------
  # read_schema
  # ------------------------------------------------------------------
  describe "#handle read_schema" do
    let(:schema_rb) { <<~RUBY }
      ActiveRecord::Schema[8.1].define(version: 2024_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.string "name"
          t.integer "age", default: 0
          t.index ["email"], name: "index_users_on_email", unique: true
        end

        create_table "posts", force: :cascade do |t|
          t.string "title"
          t.integer "user_id", null: false
          t.index ["user_id"], name: "index_posts_on_user_id"
        end

        add_index "posts", ["title"], name: "index_posts_on_title"
        add_foreign_key "posts", "users"
      end
    RUBY

    it "returns structured JSON with tables, columns, indexes, and foreign keys" do
      with_workspace do |ctx, ws|
        ws.join("db").mkpath
        ws.join("db", "schema.rb").write(schema_rb)

        response = tool_set.handle("read_schema", {}, ctx)
        expect(response).not_to be_error
        data = JSON.parse(response.content.first[:text])

        users_table = data["tables"].find { |t| t["name"] == "users" }
        expect(users_table).not_to be_nil

        col_names = users_table["columns"].map { |c| c["name"] }
        expect(col_names).to include("email", "name", "age")

        email_col = users_table["columns"].find { |c| c["name"] == "email" }
        expect(email_col["nullable"]).to be false
        expect(email_col["type"]).to eq("string")

        age_col = users_table["columns"].find { |c| c["name"] == "age" }
        expect(age_col["default"]).to eq("0")

        idx = users_table["indexes"].find { |i| i["name"] == "index_users_on_email" }
        expect(idx["unique"]).to be true
        expect(idx["columns"]).to include("email")
      end
    end

    it "applies top-level add_index to the correct table" do
      with_workspace do |ctx, ws|
        ws.join("db").mkpath
        ws.join("db", "schema.rb").write(schema_rb)

        response = tool_set.handle("read_schema", {}, ctx)
        data = JSON.parse(response.content.first[:text])
        posts_table = data["tables"].find { |t| t["name"] == "posts" }

        idx_names = posts_table["indexes"].map { |i| i["name"] }
        expect(idx_names).to include("index_posts_on_title")
      end
    end

    it "applies top-level add_foreign_key to the correct table" do
      with_workspace do |ctx, ws|
        ws.join("db").mkpath
        ws.join("db", "schema.rb").write(schema_rb)

        response = tool_set.handle("read_schema", {}, ctx)
        data = JSON.parse(response.content.first[:text])
        posts_table = data["tables"].find { |t| t["name"] == "posts" }

        fk = posts_table["foreign_keys"].first
        expect(fk["to_table"]).to eq("users")
        expect(fk["to_column"]).to eq("id")
      end
    end

    it "returns an error response when db/schema.rb is missing" do
      with_workspace do |ctx, _ws|
        response = tool_set.handle("read_schema", {}, ctx)
        expect(response).to be_error
        expect(response.content.first[:text]).to match(/not found/)
      end
    end
  end

  # ------------------------------------------------------------------
  # explain_migration
  # ------------------------------------------------------------------
  describe "#handle explain_migration" do
    let(:schema_rb) { <<~RUBY }
      ActiveRecord::Schema[8.1].define(version: 2024_01_01_000000) do
        create_table "users", force: :cascade do |t|
          t.string "email", null: false
          t.integer "age"
        end
      end
    RUBY

    let(:add_column_migration) { <<~RUBY }
      class AddNameToUsers < ActiveRecord::Migration[8.1]
        def change
          add_column :users, :name, :string
        end
      end
    RUBY

    it "reports the added column in the change summary" do
      with_workspace do |ctx, ws|
        ws.join("db").mkpath
        ws.join("db/schema.rb").write(schema_rb)
        ws.join("db/migrate").mkpath
        ws.join("db/migrate/20240101000000_add_name_to_users.rb").write(add_column_migration)

        response = tool_set.handle(
          "explain_migration",
          { "file_path" => "db/migrate/20240101000000_add_name_to_users.rb" },
          ctx
        )
        expect(response).not_to be_error
        data = JSON.parse(response.content.first[:text])

        ops = data["changes"].map { |c| c["op"] }
        expect(ops).to include("add_column")

        add_op = data["changes"].find { |c| c["op"] == "add_column" }
        expect(add_op["column"]).to eq("name")
        expect(add_op["table"]).to eq("users")
        expect(add_op["type"]).to eq("string")
      end
    end

    it "shows the column absent in before state and present in after state" do
      with_workspace do |ctx, ws|
        ws.join("db").mkpath
        ws.join("db/schema.rb").write(schema_rb)
        ws.join("db/migrate").mkpath
        ws.join("db/migrate/20240101000000_add_name_to_users.rb").write(add_column_migration)

        response = tool_set.handle(
          "explain_migration",
          { "file_path" => "db/migrate/20240101000000_add_name_to_users.rb" },
          ctx
        )
        data = JSON.parse(response.content.first[:text])

        before_cols = data["before"]["users"]&.fetch("columns", [])&.map { |c| c["name"] }
        after_cols  = data["after"]["users"]&.fetch("columns", [])&.map { |c| c["name"] }
        expect(before_cols).not_to include("name")
        expect(after_cols).to include("name")
      end
    end

    it "returns an error when file_path is missing" do
      with_workspace do |ctx, _ws|
        response = tool_set.handle("explain_migration", {}, ctx)
        expect(response).to be_error
        expect(response.content.first[:text]).to match(/file_path is required/)
      end
    end

    it "returns an error when the migration file does not exist" do
      with_workspace do |ctx, _ws|
        response = tool_set.handle(
          "explain_migration",
          { "file_path" => "db/migrate/nonexistent.rb" },
          ctx
        )
        expect(response).to be_error
        expect(response.content.first[:text]).to match(/not found/)
      end
    end
  end

  # ------------------------------------------------------------------
  # list_routes
  # ------------------------------------------------------------------
  describe "#handle list_routes" do
    let(:routes_rb) { <<~RUBY }
      Rails.application.routes.draw do
        root "dashboard#index"
        resources :jobs
        resources :users, only: %i[index show]
        scope "/api/v1" do
          resources :repositories
          get "health", to: "health#show", as: :health_check
        end
      end
    RUBY

    it "returns a list of routes" do
      with_workspace do |ctx, ws|
        ws.join("config").mkpath
        ws.join("config/routes.rb").write(routes_rb)

        response = tool_set.handle("list_routes", {}, ctx)
        expect(response).not_to be_error
        data = JSON.parse(response.content.first[:text])

        expect(data["routes"]).to be_an(Array)
        expect(data["routes"]).not_to be_empty
      end
    end

    it "includes resources routes with correct HTTP methods" do
      with_workspace do |ctx, ws|
        ws.join("config").mkpath
        ws.join("config/routes.rb").write(routes_rb)

        response = tool_set.handle("list_routes", {}, ctx)
        data = JSON.parse(response.content.first[:text])
        methods = data["routes"].map { |r| r["method"] }.uniq

        expect(methods).to include("GET", "POST", "PATCH", "DELETE")
      end
    end

    it "includes routes inside scope blocks" do
      with_workspace do |ctx, ws|
        ws.join("config").mkpath
        ws.join("config/routes.rb").write(routes_rb)

        response = tool_set.handle("list_routes", {}, ctx)
        data = JSON.parse(response.content.first[:text])
        paths = data["routes"].map { |r| r["path"] }

        expect(paths.any? { |p| p.include?("/api/v1") }).to be true
      end
    end

    it "returns an error when config/routes.rb is missing" do
      with_workspace do |ctx, _ws|
        response = tool_set.handle("list_routes", {}, ctx)
        expect(response).to be_error
        expect(response.content.first[:text]).to match(/not found/)
      end
    end
  end

  describe "#handle unknown tool" do
    it "returns an error response" do
      with_workspace do |ctx, _ws|
        response = tool_set.handle("no_such_tool", {}, ctx)
        expect(response).to be_error
      end
    end
  end
end
