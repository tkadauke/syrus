require "rails_helper"

RSpec.describe PersonalDocuments::Query do
  let(:user) { Factories.user }

  def create_document(filename:, body: "body", **attrs)
    document = user.documents.build({ kind: "file", user: }.merge(attrs))
    document.file.attach(io: StringIO.new(body), filename:, content_type: "text/plain")
    document.save!
    document
  end

  def query(tree: nil, **params)
    params[:q] = Filters::QueryParam.encode(tree) if tree
    described_class.new(user:, params: params.with_indifferent_access).call
  end

  def chip(field, op, value = nil) = { field:, op:, value: }

  it "falls back to an empty filter for a malformed AST" do
    document = create_document(filename: "kept.txt")
    expect(query(tree: { invalid: [] }).documents).to eq([ document ])
  end

  it "matches query text aggregated from document metadata" do
    matching = create_document(filename: "cached-notes.txt")
    create_document(filename: "other.txt")
    expect(query(tree: { and: [ chip("query", "contains", "cached") ] }).documents).to eq([ matching ])
  end

  it "supports negative text matching" do
    kept = create_document(filename: "kept.txt")
    create_document(filename: "excluded.txt")
    tree = { and: [ chip("title", "is_not", "excluded.txt") ] }
    expect(query(tree:).documents).to eq([ kept ])
  end

  it "supports every numeric comparison operator" do
    small = create_document(filename: "small.txt", body: "s" * 10)
    exact = create_document(filename: "exact.txt", body: "e" * 20)
    large = create_document(filename: "large.txt", body: "l" * 30)

    expect(query(tree: { and: [ chip("byte_size", "gt", 20) ] }).documents).to eq([ large ])
    expect(query(tree: { and: [ chip("byte_size", "gte", 20) ] }).documents).to contain_exactly(exact, large)
    expect(query(tree: { and: [ chip("byte_size", "lt", 20) ] }).documents).to eq([ small ])
    expect(query(tree: { and: [ chip("byte_size", "lte", 20) ] }).documents).to contain_exactly(small, exact)
  end

  it "supports open and closed date ranges" do
    before = create_document(filename: "before.txt", created_at: Time.zone.parse("2026-01-01"))
    inside = create_document(filename: "inside.txt", created_at: Time.zone.parse("2026-01-15"))
    after = create_document(filename: "after.txt", created_at: Time.zone.parse("2026-02-01"))

    closed = query(tree: { and: [ chip("created_at", "between", [ "2026-01-10", "2026-01-20" ]) ] })
    open_ended = query(tree: { and: [ chip("created_at", "between", [ "2026-01-10", "" ]) ] })
    expect(closed.documents).to eq([ inside ])
    expect(open_ended.documents).to contain_exactly(inside, after)
    expect(open_ended.documents).not_to include(before)
  end

  it "uses ids as a tie breaker when sorting equal values" do
    first = create_document(filename: "first.txt", created_at: Time.zone.parse("2026-01-01"))
    second = create_document(filename: "second.txt", created_at: Time.zone.parse("2026-01-01"))
    expect(query(sort: "created_at", direction: "ascending").documents).to eq([ first, second ])
    expect(query(sort: "created_at", direction: "descending").documents).to eq([ second, first ])
  end

  it "clamps requested pages to the available boundary" do
    26.times { |index| create_document(filename: "page-#{index}.txt") }
    result = query(page: 99)
    expect(result.page).to eq(2)
    expect(result.total_pages).to eq(2)
    expect(result.documents.length).to eq(1)
  end
end
