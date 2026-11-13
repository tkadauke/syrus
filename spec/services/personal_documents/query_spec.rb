require "rails_helper"

RSpec.describe PersonalDocuments::Query do
  let(:user) { Factories.user }

  def create_document(url:, **attrs)
    user.documents.create!({ kind: "google_doc", google_doc_url: url, source_url: url, user: }.merge(attrs))
  end

  def query(tree: nil, **params)
    params[:q] = Filters::QueryParam.encode(tree) if tree
    described_class.new(user:, params: params.with_indifferent_access).call
  end

  def chip(field, op, value = nil) = { field:, op:, value: }

  it "falls back to an empty filter for a malformed AST" do
    document = create_document(url: "https://docs.google.com/document/d/kept/edit")
    expect(query(tree: { invalid: [] }).documents).to eq([ document ])
  end

  it "matches query text aggregated from document metadata" do
    matching = create_document(url: "https://docs.google.com/document/d/ordinary/edit", content_cache: "cached body")
    create_document(url: "https://docs.google.com/document/d/other/edit")
    expect(query(tree: { and: [ chip("query", "contains", "cached") ] }).documents).to eq([ matching ])
  end

  it "supports negative text matching" do
    kept = create_document(url: "https://docs.google.com/document/d/kept/edit")
    create_document(url: "https://docs.google.com/document/d/excluded/edit")
    tree = { and: [ chip("title", "is_not", "https://docs.google.com/document/d/excluded/edit") ] }
    expect(query(tree:).documents).to eq([ kept ])
  end

  it "supports every numeric comparison operator" do
    small = create_document(url: "https://docs.google.com/document/d/small/edit", byte_size: 10)
    exact = create_document(url: "https://docs.google.com/document/d/exact/edit", byte_size: 20)
    large = create_document(url: "https://docs.google.com/document/d/large/edit", byte_size: 30)

    expect(query(tree: { and: [ chip("byte_size", "gt", 20) ] }).documents).to eq([ large ])
    expect(query(tree: { and: [ chip("byte_size", "gte", 20) ] }).documents).to contain_exactly(exact, large)
    expect(query(tree: { and: [ chip("byte_size", "lt", 20) ] }).documents).to eq([ small ])
    expect(query(tree: { and: [ chip("byte_size", "lte", 20) ] }).documents).to contain_exactly(small, exact)
  end

  it "supports open and closed date ranges" do
    before = create_document(url: "https://docs.google.com/document/d/before/edit", content_cached_at: Time.zone.parse("2026-01-01"))
    inside = create_document(url: "https://docs.google.com/document/d/inside/edit", content_cached_at: Time.zone.parse("2026-01-15"))
    after = create_document(url: "https://docs.google.com/document/d/after/edit", content_cached_at: Time.zone.parse("2026-02-01"))

    closed = query(tree: { and: [ chip("content_cached_at", "between", [ "2026-01-10", "2026-01-20" ]) ] })
    open_ended = query(tree: { and: [ chip("content_cached_at", "between", [ "2026-01-10", "" ]) ] })
    expect(closed.documents).to eq([ inside ])
    expect(open_ended.documents).to contain_exactly(inside, after)
    expect(open_ended.documents).not_to include(before)
  end

  it "sorts missing values consistently and uses ids as a tie breaker" do
    missing = create_document(url: "https://docs.google.com/document/d/missing/edit")
    first = create_document(url: "https://docs.google.com/document/d/first/edit", content_cached_at: Time.zone.parse("2026-01-01"))
    second = create_document(url: "https://docs.google.com/document/d/second/edit", content_cached_at: Time.zone.parse("2026-01-01"))
    expect(query(sort: "content_cached_at", direction: "ascending").documents).to eq([ missing, first, second ])
    expect(query(sort: "content_cached_at", direction: "descending").documents).to eq([ second, first, missing ])
  end

  it "clamps requested pages to the available boundary" do
    26.times { |index| create_document(url: "https://docs.google.com/document/d/page-#{index}/edit") }
    result = query(page: 99)
    expect(result.page).to eq(2)
    expect(result.total_pages).to eq(2)
    expect(result.documents.length).to eq(1)
  end
end
