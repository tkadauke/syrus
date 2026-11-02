require "rails_helper"
require Rails.root.join("plugins/design_docs/db/migrate/20260919211614_enlarge_design_doc_markdown_columns_to_mediumtext")

RSpec.describe EnlargeDesignDocMarkdownColumnsToMediumtext do
  let(:migration) { described_class.new }
  let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "Mysql2") }

  before do
    allow(migration).to receive(:connection).and_return(connection)
    allow(connection).to receive(:column_exists?).and_return(true)
    allow(connection).to receive(:change_column)
  end

  it "promotes document-sized Markdown columns to MEDIUMTEXT on MySQL" do
    migration.up

    described_class::PROMOTIONS.each do |table, column|
      expect(connection).to have_received(:change_column).with(table.to_s, column, :text, limit: 16.megabytes)
    end
    expect(connection).not_to have_received(:change_column).with("design_doc_comments", :body, anything)
  end

  it "does not apply MySQL-specific limits on SQLite" do
    allow(connection).to receive(:adapter_name).and_return("SQLite")

    migration.up

    expect(connection).not_to have_received(:change_column)
  end
end
