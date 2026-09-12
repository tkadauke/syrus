require "rails_helper"
require "rake"

RSpec.describe DesignDocs::SearchSource, type: :service do
  before(:all) { Rails.application.load_tasks }

  before do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS design_doc_fts")
    SearchRecord.connection.execute(described_class::TABLE_SQL)
  end

  it "declares the Design Docs search table and result type" do
    expect(described_class.search_tables).to include("design_doc_fts" => described_class::TABLE_SQL)
    expect(described_class.search_type).to eq("design_doc")
    expect(described_class.row_id_key).to eq(:design_doc_id)
  end

  it "filters scopes through DesignDocs::DesignDoc.visible_to" do
    owner = Factories.user
    viewer = Factories.user
    private_doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Private runtime", markdown: "runtime")
    visible_doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Visible runtime", markdown: "runtime")
    visible_doc.collaborators.create!(user: viewer, role: "viewer", added_by_user: owner)

    filtered = described_class.filtered_scope(
      ids: [ private_doc.id, visible_doc.id ],
      tree: { "and" => [] },
      user: viewer
    )

    expect(filtered).to contain_exactly(visible_doc)
  end

  it "serializes only visible results" do
    owner = Factories.user
    outsider = Factories.user
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Private runtime", markdown: "runtime")
    row = { design_doc_id: doc.id, snippet: "runtime", rank: 0.0 }

    expect(described_class.result_json(row: row, user: outsider)).to be_nil
    expect(described_class.result_json(row: row, user: owner)).to include(
      type: "design_doc",
      id: doc.id,
      slug: doc.display_id,
      path: "/design_docs/#{doc.id}",
      visibility: "private"
    )
  end

  it "rebuilds the index through the backfill hook" do
    owner = Factories.user
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Backfilled runtime", markdown: "runtime")

    described_class.backfill_search_table("design_doc_fts")

    expect(DesignDocs::SearchIndex.search("runtime", user: owner)).to include(include(design_doc_id: doc.id))
  end

  it "is withheld when either plugin is disabled" do
    expect(Syrus::PluginRegistry.providers_for("global_search:source")).to include(described_class)

    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: false, disableable: true)
    expect(Syrus::PluginRegistry.providers_for("global_search:source")).not_to include(described_class)

    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: true, disableable: true)
    PluginRecord.find_or_create_by!(name: "design_docs").update!(enabled: false, disableable: true)
    expect(Syrus::PluginRegistry.providers_for("global_search:source")).not_to include(described_class)
  end

  it "prepares and backfills only when global search is available" do
    calls = []
    allow(SyrusSearchDatabaseTasks).to receive(:prepare!) { calls << :prepare }
    allow(described_class).to receive(:backfill_search_table) { |name| calls << name }

    DesignDocs::Callbacks.on_enable
    expect(calls).to eq([ :prepare, "design_doc_fts" ])

    calls.clear
    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: false, disableable: true)

    DesignDocs::Callbacks.on_enable
    expect(calls).to eq([])
  end

  it "lets global_search re-enable catch up Design Docs changes" do
    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: false, disableable: true)
    SearchRecord.connection.execute("DELETE FROM design_doc_fts")
    owner = Factories.user
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Offline runtime", markdown: "catchup runtime")

    expect(DesignDocs::SearchIndex.search("catchup", user: owner)).to eq([])

    PluginRecord.find_or_create_by!(name: "global_search").update!(enabled: true, disableable: true)
    GlobalSearch::Callbacks.on_enable

    expect(DesignDocs::SearchIndex.search("catchup", user: owner)).to include(include(design_doc_id: doc.id))
  end

  it "lets design_docs re-enable rebuild from current source of truth" do
    owner = Factories.user
    stale_doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Stale runtime", markdown: "stale runtime")
    fresh_doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: "Fresh runtime", markdown: "fresh runtime")
    DesignDocs::SearchIndex.upsert(stale_doc)
    stale_doc.destroy!

    PluginRecord.find_or_create_by!(name: "design_docs").update!(enabled: false, disableable: true)
    PluginRecord.find_or_create_by!(name: "design_docs").update!(enabled: true, disableable: true)
    DesignDocs::Callbacks.on_enable

    ids = DesignDocs::SearchIndex.search("runtime", user: owner, limit: 10).map { |row| row.fetch(:design_doc_id) }
    expect(ids).to contain_exactly(fresh_doc.id)
  end
end
