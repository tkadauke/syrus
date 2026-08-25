require "rails_helper"

RSpec.describe MysqlDbBrowser::QueryBuilderCompiler do
  def column(name:, data_type: "varchar", column_type: data_type)
    { name: name, data_type: data_type, column_type: column_type }
  end

  let(:orders_columns) do
    [
      column(name: "id", data_type: "bigint"),
      column(name: "status", data_type: "varchar", column_type: "varchar(20)"),
      column(name: "total", data_type: "decimal"),
      column(name: "customer_id", data_type: "bigint")
    ]
  end

  let(:customers_columns) do
    [
      column(name: "id", data_type: "bigint"),
      column(name: "name", data_type: "varchar", column_type: "varchar(255)")
    ]
  end

  def compiler(spec, join_table: nil, join_columns: [])
    described_class.new(spec: spec, base_table: "orders", base_columns: orders_columns, join_table: join_table, join_columns: join_columns)
  end

  it "selects explicit qualified columns from the base table" do
    sql = compiler({ table: "orders", columns: [ "orders.id", "orders.status" ] }).sql

    expect(sql).to eq("SELECT `orders`.`id`, `orders`.`status` FROM `orders` LIMIT 100")
  end

  it "defaults to SELECT * for the base table when no columns are given" do
    sql = compiler({ table: "orders" }).sql

    expect(sql).to eq("SELECT `orders`.* FROM `orders` LIMIT 100")
  end

  it "raises InvalidSpec for a column not present on the resolved table" do
    expect {
      compiler({ table: "orders", columns: [ "orders.nope" ] })
    }.to raise_error(described_class::InvalidSpec, /unknown column/)
  end

  it "raises InvalidSpec for an unqualified column reference" do
    expect {
      compiler({ table: "orders", columns: [ "status" ] })
    }.to raise_error(described_class::InvalidSpec, /must be qualified/)
  end

  describe "aggregate mode" do
    it "builds COUNT(*), SUM, and GROUP BY with default aliases" do
      spec = {
        table: "orders",
        aggregations: [
          { function: "count", column: "*" },
          { function: "sum", column: "orders.total" }
        ],
        group_by: [ "orders.status" ]
      }

      sql = compiler(spec).sql

      expect(sql).to eq(
        "SELECT `orders`.`status`, COUNT(*) AS `row_count`, SUM(`orders`.`total`) AS `sum_total` " \
        "FROM `orders` GROUP BY `orders`.`status` LIMIT 100"
      )
    end

    it "uses a caller-supplied alias when given" do
      spec = { table: "orders", aggregations: [ { function: "sum", column: "orders.total", alias: "revenue" } ] }

      expect(compiler(spec).sql).to include("SUM(`orders`.`total`) AS `revenue`")
    end

    it "rejects count(*) style syntax for non-count aggregations" do
      spec = { table: "orders", aggregations: [ { function: "sum", column: "*" } ] }

      expect { compiler(spec).sql }.to raise_error(described_class::InvalidSpec, /only supported for count/)
    end

    it "rejects an unknown aggregation function" do
      spec = { table: "orders", aggregations: [ { function: "median", column: "orders.total" } ] }

      expect { compiler(spec) }.to raise_error(described_class::InvalidSpec, /unknown aggregation function/)
    end

    it "rejects group_by without any aggregations" do
      expect {
        compiler({ table: "orders", group_by: [ "orders.status" ] })
      }.to raise_error(described_class::InvalidSpec, /requires at least one aggregation/)
    end

    it "rejects an alias that is not a simple identifier" do
      spec = { table: "orders", aggregations: [ { function: "count", column: "*", alias: "not ok; --" } ] }

      expect { compiler(spec) }.to raise_error(described_class::InvalidSpec, /simple identifier/)
    end
  end

  describe "joins" do
    let(:join_spec) { { table: "customers", type: "left", from_column: "orders.customer_id", to_column: "customers.id" } }

    it "emits a LEFT JOIN and qualifies default-star columns from both tables" do
      sql = compiler({ table: "orders", join: join_spec }, join_table: "customers", join_columns: customers_columns).sql

      expect(sql).to eq(
        "SELECT `orders`.*, `customers`.* FROM `orders` LEFT JOIN `customers` ON `orders`.`customer_id` = `customers`.`id` LIMIT 100"
      )
    end

    it "supports selecting columns from the joined table" do
      spec = { table: "orders", columns: [ "orders.id", "customers.name" ], join: join_spec }
      sql = compiler(spec, join_table: "customers", join_columns: customers_columns).sql

      expect(sql).to include("SELECT `orders`.`id`, `customers`.`name` FROM `orders`")
    end

    it "defaults the join type to LEFT when omitted" do
      spec = { table: "orders", join: join_spec.except(:type) }
      sql = compiler(spec, join_table: "customers", join_columns: customers_columns).sql

      expect(sql).to include("LEFT JOIN `customers`")
    end

    it "supports an INNER join" do
      spec = { table: "orders", join: join_spec.merge(type: "inner") }
      sql = compiler(spec, join_table: "customers", join_columns: customers_columns).sql

      expect(sql).to include("INNER JOIN `customers`")
    end

    it "rejects an unknown join type" do
      spec = { table: "orders", join: join_spec.merge(type: "full outer") }

      expect {
        compiler(spec, join_table: "customers", join_columns: customers_columns)
      }.to raise_error(described_class::InvalidSpec, /unknown join type/)
    end

    it "allows a join column from either side of the pair, as long as it is a real column" do
      spec = { table: "orders", join: join_spec.merge(from_column: "customers.name") }

      expect {
        compiler(spec, join_table: "customers", join_columns: customers_columns)
      }.not_to raise_error
    end

    it "rejects a join column that does not exist on its declared table" do
      spec = { table: "orders", join: join_spec.merge(to_column: "customers.missing") }

      expect {
        compiler(spec, join_table: "customers", join_columns: customers_columns)
      }.to raise_error(described_class::InvalidSpec, /unknown column/)
    end
  end

  describe "sort" do
    it "sorts by a selected column in plain mode" do
      spec = { table: "orders", columns: [ "orders.status" ], sort: { column: "orders.status", direction: "desc" } }

      expect(compiler(spec).sql).to include("ORDER BY `orders`.`status` DESC LIMIT")
    end

    it "rejects sorting by a column that was not selected in plain mode" do
      spec = { table: "orders", columns: [ "orders.status" ], sort: { column: "orders.total", direction: "asc" } }

      expect { compiler(spec).sql }.to raise_error(described_class::InvalidSpec, /was not selected/)
    end

    it "allows sorting by any real column when the select list defaults to *" do
      spec = { table: "orders", sort: { column: "orders.total", direction: "asc" } }

      expect(compiler(spec).sql).to include("ORDER BY `orders`.`total` ASC")
    end

    it "sorts by an aggregation alias in aggregate mode" do
      spec = { table: "orders", aggregations: [ { function: "count", column: "*", alias: "n" } ], sort: { column: "n", direction: "desc" } }

      expect(compiler(spec).sql).to include("ORDER BY `n` DESC")
    end

    it "sorts by a group_by column in aggregate mode" do
      spec = {
        table: "orders",
        aggregations: [ { function: "count", column: "*" } ],
        group_by: [ "orders.status" ],
        sort: { column: "orders.status", direction: "asc" }
      }

      expect(compiler(spec).sql).to include("ORDER BY `orders`.`status` ASC")
    end

    it "rejects sorting by something that is neither a group_by column nor an aggregation alias" do
      spec = { table: "orders", aggregations: [ { function: "count", column: "*" } ], sort: { column: "orders.total", direction: "asc" } }

      expect { compiler(spec).sql }.to raise_error(described_class::InvalidSpec, /not a group-by column or aggregation alias/)
    end
  end

  describe "malformed spec shapes (defense in depth beyond controller-level guards)" do
    it "rejects a join that is not an object instead of raising a TypeError" do
      expect {
        compiler({ table: "orders", join: "customers" }, join_table: "customers", join_columns: customers_columns)
      }.to raise_error(described_class::InvalidSpec, /join must be an object/)
    end

    it "rejects an aggregation entry that is not an object instead of raising a TypeError" do
      expect {
        compiler({ table: "orders", aggregations: [ "count(*)" ] })
      }.to raise_error(described_class::InvalidSpec, /each aggregation must be an object/)
    end

    it "rejects a sort that is not an object instead of raising a TypeError" do
      expect {
        compiler({ table: "orders", sort: "status desc" })
      }.to raise_error(described_class::InvalidSpec, /sort must be an object/)
    end

    it "degrades a non-Hash spec to an empty spec rather than raising a NoMethodError" do
      sql = described_class.new(spec: "garbage", base_table: "orders", base_columns: orders_columns).sql

      expect(sql).to eq("SELECT `orders`.* FROM `orders` LIMIT 100")
    end
  end

  describe "limit" do
    it "defaults to 100" do
      expect(compiler({ table: "orders" }).limit).to eq(100)
    end

    it "clamps to the maximum of 500" do
      expect(compiler({ table: "orders", limit: 10_000 }).limit).to eq(500)
    end

    it "clamps below 1 up to 1" do
      expect(compiler({ table: "orders", limit: 0 }).limit).to eq(1)
    end
  end

  describe "#filter_schema" do
    it "builds a base-table-only schema with no join" do
      fields = compiler({ table: "orders" }).filter_schema

      expect(fields.map { |f| f[:field] }).to contain_exactly("orders.id", "orders.status", "orders.total", "orders.customer_id")
    end

    it "includes the joined table's columns when a join is present" do
      spec = { table: "orders", join: { table: "customers", from_column: "orders.customer_id", to_column: "customers.id" } }
      fields = compiler(spec, join_table: "customers", join_columns: customers_columns).filter_schema

      expect(fields.map { |f| f[:field] }).to include("customers.id", "customers.name")
    end
  end

  it "raises InvalidSpec for a column referencing a table outside the base/join pair" do
    expect {
      compiler({ table: "orders", columns: [ "customers.name" ] })
    }.to raise_error(described_class::InvalidSpec, /unknown table/)
  end

  it "raises InvalidSpec when base_table is blank" do
    expect {
      described_class.new(spec: {}, base_table: "", base_columns: orders_columns)
    }.to raise_error(described_class::InvalidSpec, /table is required/)
  end
end
