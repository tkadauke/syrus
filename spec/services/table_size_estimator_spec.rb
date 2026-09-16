require "rails_helper"

RSpec.describe TableSizeEstimator do
  let(:connection) { ActiveRecord::Base.connection }

  describe ".estimate" do
    context "when the adapter is MySQL" do
      before { allow(connection).to receive(:adapter_name).and_return("Mysql2") }

      it "reads InnoDB engine estimates from information_schema.TABLES" do
        allow(connection).to receive(:select_one).and_return("row_count" => 4200, "byte_size" => 819_200)

        result = described_class.estimate("notifications")

        expect(result.table_name).to eq("notifications")
        expect(result.row_count_estimate).to eq(4200)
        expect(result.byte_size_estimate).to eq(819_200)
      end

      it "scopes the query to the current schema and the quoted table name, never COUNT(*)" do
        expect(connection).to receive(:select_one) do |sql, _name|
          expect(sql).to include("information_schema.TABLES")
          expect(sql).to include("table_schema = DATABASE()")
          expect(sql).to include(connection.quote("notifications"))
          expect(sql).not_to match(/COUNT\(\*\)/i)
          nil
        end

        described_class.estimate("notifications")
      end

      it "returns nil estimates when the table has no information_schema row" do
        allow(connection).to receive(:select_one).and_return(nil)

        result = described_class.estimate("ghost_table")

        expect(result.row_count_estimate).to be_nil
        expect(result.byte_size_estimate).to be_nil
      end
    end

    context "when the adapter is SQLite" do
      before { allow(connection).to receive(:adapter_name).and_return("SQLite") }

      it "estimates row count via MAX(rowid) and byte size via dbstat when dbstat is available" do
        allow(connection).to receive(:select_value).with("SELECT 1 FROM dbstat LIMIT 1").and_return(1)
        allow(connection).to receive(:select_value)
          .with("SELECT MAX(rowid) FROM #{connection.quote_table_name('notifications')}")
          .and_return(500)
        allow(connection).to receive(:select_value)
          .with("SELECT SUM(pgsize) FROM dbstat WHERE name = #{connection.quote('notifications')}")
          .and_return(65_536)

        result = described_class.estimate("notifications")

        expect(result.row_count_estimate).to eq(500)
        expect(result.byte_size_estimate).to eq(65_536)
      end

      it "falls back to a nil byte size when the SQLite build lacks dbstat support" do
        allow(connection).to receive(:select_value)
          .with("SELECT 1 FROM dbstat LIMIT 1")
          .and_raise(ActiveRecord::StatementInvalid, "no such table: dbstat")
        allow(connection).to receive(:select_value)
          .with("SELECT MAX(rowid) FROM #{connection.quote_table_name('notifications')}")
          .and_return(500)

        result = described_class.estimate("notifications")

        expect(result.row_count_estimate).to eq(500)
        expect(result.byte_size_estimate).to be_nil
      end

      it "returns a nil row count when the rowid query fails (e.g. a WITHOUT ROWID table)" do
        allow(connection).to receive(:select_value).with("SELECT 1 FROM dbstat LIMIT 1").and_return(1)
        allow(connection).to receive(:select_value)
          .with("SELECT MAX(rowid) FROM #{connection.quote_table_name('missing_table')}")
          .and_raise(ActiveRecord::StatementInvalid, "no such table: missing_table")
        allow(connection).to receive(:select_value)
          .with("SELECT SUM(pgsize) FROM dbstat WHERE name = #{connection.quote('missing_table')}")
          .and_return(nil)

        result = described_class.estimate("missing_table")

        expect(result.row_count_estimate).to be_nil
      end
    end
  end
end
