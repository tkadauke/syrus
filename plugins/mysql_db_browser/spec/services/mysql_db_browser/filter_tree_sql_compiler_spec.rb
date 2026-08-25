require "rails_helper"

RSpec.describe MysqlDbBrowser::FilterTreeSqlCompiler do
  let(:client) do
    instance_double(Mysql2::Client).tap do |c|
      # Real MySQL escaping doubles backslashes and backslash-escapes quotes;
      # block-form gsub keeps the replacement text literal (no backreference
      # ambiguity from backslashes in a String replacement argument).
      allow(c).to receive(:escape) { |value| value.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" } }
    end
  end
  let(:filter_schema) { MysqlDbBrowser::FilterSchemaBuilder.build(columns) }
  let(:columns) do
    [
      { name: "email", data_type: "varchar", column_type: "varchar(255)" },
      { name: "amount_cents", data_type: "int", column_type: "int(11)" },
      { name: "active", data_type: "tinyint", column_type: "tinyint(1)" },
      { name: "created_at", data_type: "datetime", column_type: "datetime" },
      { name: "state", data_type: "enum", column_type: "enum('pending','active','done')" }
    ]
  end

  def compiler = described_class.new(client: client, filter_schema: filter_schema)

  it "returns nil for an empty filter tree" do
    expect(compiler.compile({})).to be_nil
    expect(compiler.compile({ "and" => [] })).to be_nil
  end

  it "compiles a string contains chip to a LIKE with escaped wildcards" do
    sql = compiler.compile({ "and" => [ { "field" => "email", "op" => "contains", "value" => "100%_off" } ] })

    expect(sql).to eq("(`email` LIKE '%100\\\\%\\\\_off%')")
  end

  it "compiles string equals/not_equals/is_set/is_unset" do
    expect(compiler.compile({ "and" => [ { "field" => "email", "op" => "equals", "value" => "a@example.com" } ] }))
      .to eq("(`email` = 'a@example.com')")
    expect(compiler.compile({ "and" => [ { "field" => "email", "op" => "is_set" } ] }))
      .to eq("((`email` IS NOT NULL AND `email` <> ''))")
  end

  it "compiles number chips including between" do
    sql = compiler.compile({ "and" => [ { "field" => "amount_cents", "op" => "between", "value" => [ 100, 500 ] } ] })
    expect(sql).to eq("(`amount_cents` BETWEEN 100.0 AND 500.0)")
  end

  it "compiles boolean chips" do
    expect(compiler.compile({ "and" => [ { "field" => "active", "op" => "is_true" } ] })).to eq("(`active` = 1)")
    expect(compiler.compile({ "and" => [ { "field" => "active", "op" => "is_false" } ] })).to eq("(`active` = 0)")
  end

  it "compiles date within_last chips relative to the current time" do
    travel_to Time.zone.parse("2026-08-24 12:00:00") do
      sql = compiler.compile({ "and" => [ { "field" => "created_at", "op" => "within_last", "value" => { "n" => 7, "unit" => "days" } } ] })
      expect(sql).to eq("(`created_at` >= '2026-08-17 12:00:00')")
    end
  end

  it "compiles enum is_one_of to an IN clause" do
    sql = compiler.compile({ "and" => [ { "field" => "state", "op" => "is_one_of", "value" => %w[pending active] } ] })
    expect(sql).to eq("(`state` IN ('pending', 'active'))")
  end

  it "combines AND/OR/NOT nodes" do
    tree = {
      "and" => [
        { "field" => "active", "op" => "is_true" },
        { "not" => { "field" => "email", "op" => "is_set" } }
      ]
    }

    sql = compiler.compile(tree)
    expect(sql).to eq("(`active` = 1) AND (NOT ((`email` IS NOT NULL AND `email` <> '')))")
  end

  it "raises UnknownField for a field not present in the filter schema" do
    expect {
      compiler.compile({ "and" => [ { "field" => "nope", "op" => "equals", "value" => "x" } ] })
    }.to raise_error(described_class::UnknownField)
  end

  it "raises UnsupportedOperator when the operator isn't valid for the field's bucket" do
    expect {
      compiler.compile({ "and" => [ { "field" => "amount_cents", "op" => "contains", "value" => "1" } ] })
    }.to raise_error(described_class::UnsupportedOperator)
  end

  it "quotes identifiers so a column-name-shaped field can never break out of backticks" do
    tricky_schema = MysqlDbBrowser::FilterSchemaBuilder.build([ { name: "weird`name", data_type: "varchar", column_type: "varchar(10)" } ])
    sql = described_class.new(client: client, filter_schema: tricky_schema).compile({ "and" => [ { "field" => "weird`name", "op" => "is_set" } ] })

    expect(sql).to eq("((`weird``name` IS NOT NULL AND `weird``name` <> ''))")
  end
end
