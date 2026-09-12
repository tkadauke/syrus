require "rails_helper"

RSpec.describe DesignDocs::SearchIndex, type: :model do
  let(:owner) { Factories.user(email_address: "owner@example.com") }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  before { prepare_search_table }

  it "indexes title, marker-stripped body, preview text, repositories, and people metadata" do
    collaborator = Factories.user(email_address: "editor@example.com")
    doc = create_design_doc(
      title: "Target Graph Runtime",
      markdown: "Alpha <!-- syrus:range-start id=\"abc\" -->hidden<!-- syrus:range-end id=\"abc\" --> beta",
      repository: repository
    )
    doc.collaborators.create!(user: collaborator, role: "viewer", added_by_user: owner)

    described_class.upsert(doc.reload)

    expect(search_titles("Target", owner)).to eq([ "Target Graph Runtime" ])
    expect(search_titles("beta", owner)).to eq([ "Target Graph Runtime" ])
    expect(search_titles("widgets", owner)).to eq([ "Target Graph Runtime" ])
    expect(search_titles("editor@example.com", owner)).to eq([ "Target Graph Runtime" ])
    expect(search_titles("syrus:range-start", owner)).to be_empty
  end

  it "puts an exact DOC lookup ahead of ordinary full-text matches" do
    exact = create_design_doc(title: "Runtime plan", markdown: "ordinary body")
    other = create_design_doc(title: "DOC mention", markdown: exact.display_id)
    [ other, exact ].each { |doc| described_class.upsert(doc) }

    rows = described_class.search(exact.display_id, user: owner, limit: 10)

    expect(rows.first).to include(design_doc_id: exact.id, rank: -1.0, snippet: "<mark>#{exact.display_id}</mark>")
  end

  it "filters every search result through DesignDoc.visible_to" do
    invisible = create_design_doc(title: "Secret runtime", markdown: "private runtime")
    visible = create_design_doc(title: "Shared runtime", markdown: "public runtime", visibility: "public", repository: repository)
    member = Factories.user
    repository.repository_memberships.create!(user: member, role: "read")
    [ invisible, visible ].each { |doc| described_class.upsert(doc) }

    expect(search_titles("runtime", member)).to eq([ "Shared runtime" ])
  end

  it "deletes stale rows before rebuilding from source of truth" do
    doc = create_design_doc(title: "Fresh runtime", markdown: "fresh body")
    insert_stale_row(99_999, "Stale runtime")

    described_class.rebuild!

    ids = SearchRecord.connection.select_values("SELECT design_doc_id FROM design_doc_fts ORDER BY design_doc_id").map(&:to_i)
    expect(ids).to eq([ doc.id ])
  end

  it "is a no-op when the search table is absent" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS design_doc_fts")
    doc = create_design_doc(title: "No table", markdown: "body")

    expect { described_class.upsert(doc) }.not_to raise_error
    expect { described_class.rebuild! }.not_to raise_error
    expect(described_class.search("table", user: owner)).to eq([])
  end

  def search_titles(query, user)
    ids = described_class.search(query, user: user, limit: 10).map { |row| row.fetch(:design_doc_id) }
    DesignDocs::DesignDoc.where(id: ids).order(:id).pluck(:title)
  end

  def create_design_doc(title:, markdown:, visibility: "private", repository: nil)
    doc = DesignDocs::DesignDoc.create!(owner_user: owner, title: title, markdown: markdown, visibility: visibility)
    doc.repositories << repository if repository
    doc
  end

  def insert_stale_row(id, title)
    SearchRecord.connection.exec_insert(
      <<~SQL.squish,
        INSERT INTO design_doc_fts (
          display_id, title, body, preview_text, repository_text, owner_text, collaborator_text,
          design_doc_id, owner_user_id, visibility, state, created_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
      "Insert stale design doc search row",
      [
        ActiveRecord::Relation::QueryAttribute.new("display_id", "DOC-#{id}", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("title", title, ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("body", "stale body", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("preview_text", "stale body", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("repository_text", "", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("owner_text", "", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("collaborator_text", "", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("design_doc_id", id, ActiveRecord::Type::Integer.new),
        ActiveRecord::Relation::QueryAttribute.new("owner_user_id", owner.id, ActiveRecord::Type::Integer.new),
        ActiveRecord::Relation::QueryAttribute.new("visibility", "private", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("state", "draft", ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("created_at", Time.current.iso8601, ActiveRecord::Type::String.new),
        ActiveRecord::Relation::QueryAttribute.new("updated_at", Time.current.iso8601, ActiveRecord::Type::String.new)
      ]
    )
  end

  def prepare_search_table
    SearchRecord.connection.execute("DROP TABLE IF EXISTS design_doc_fts")
    SearchRecord.connection.execute(DesignDocs::SearchSource::TABLE_SQL)
  end
end
