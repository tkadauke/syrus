require "rails_helper"

RSpec.describe CoverageAnalysis::MergeStrategy do
  def merge(*raws)
    described_class.merge_all(raws)
  end

  def raw(hit_map: {}, lf: 0, lh: 0, brf: 0, brh: 0, fnf: 0, fnh: 0, file_stats: {})
    { hit_map: hit_map, lf: lf, lh: lh, brf: brf, brh: brh, fnf: fnf, fnh: fnh, file_stats: file_stats }
  end

  it "returns an empty merged result for an empty input" do
    result = merge
    expect(result[:hit_map]).to be_empty
    expect(result[:lf]).to eq(0)
    expect(result[:lh]).to eq(0)
  end

  it "returns a single raw unchanged when given one input" do
    r = raw(
      hit_map: { "app/foo.rb" => { "1" => 3, "2" => 0 } },
      lf: 2, lh: 1,
      file_stats: { "app/foo.rb" => { lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    )

    result = merge(r)
    expect(result[:hit_map]).to eq({ "app/foo.rb" => { "1" => 3, "2" => 0 } })
    expect(result[:lf]).to eq(2)
    expect(result[:lh]).to eq(1)
  end

  it "sums line hit counts for the same file across sources" do
    a = raw(hit_map: { "app/foo.rb" => { "1" => 2, "2" => 0 } })
    b = raw(hit_map: { "app/foo.rb" => { "1" => 3, "2" => 1 } })

    result = merge(a, b)
    expect(result[:hit_map]["app/foo.rb"]).to eq({ "1" => 5, "2" => 1 })
  end

  it "includes files that appear in only one of the inputs" do
    a = raw(hit_map: { "app/foo.rb" => { "1" => 1 } })
    b = raw(hit_map: { "app/bar.rb" => { "5" => 2 } })

    result = merge(a, b)
    expect(result[:hit_map].keys).to contain_exactly("app/foo.rb", "app/bar.rb")
  end

  it "accumulates lf/lh totals across sources" do
    a = raw(lf: 10, lh: 7)
    b = raw(lf: 5,  lh: 3)

    result = merge(a, b)
    expect(result[:lf]).to eq(15)
    expect(result[:lh]).to eq(10)
  end

  it "accumulates branch and function totals across sources" do
    a = raw(brf: 4, brh: 2, fnf: 3, fnh: 1)
    b = raw(brf: 6, brh: 5, fnf: 2, fnh: 2)

    result = merge(a, b)
    expect(result[:brf]).to eq(10)
    expect(result[:brh]).to eq(7)
    expect(result[:fnf]).to eq(5)
    expect(result[:fnh]).to eq(3)
  end

  it "merges per-file stats by summing their fields" do
    stats_a = { lf: 10, lh: 7, brf: 4, brh: 2, fnf: 1, fnh: 1 }
    stats_b = { lf: 5,  lh: 5, brf: 2, brh: 2, fnf: 1, fnh: 0 }

    a = raw(file_stats: { "app/foo.rb" => stats_a })
    b = raw(file_stats: { "app/foo.rb" => stats_b })

    result = merge(a, b)
    merged_stats = result[:file_stats]["app/foo.rb"]
    expect(merged_stats).to eq({ lf: 15, lh: 12, brf: 6, brh: 4, fnf: 2, fnh: 1 })
  end

  it "handles a nil or missing hit_map key without raising" do
    a = raw(hit_map: nil, file_stats: nil)
    b = raw(hit_map: { "app/foo.rb" => { "1" => 1 } }, lf: 1, lh: 1)

    result = merge(a, b)
    expect(result[:hit_map]).to eq({ "app/foo.rb" => { "1" => 1 } })
    expect(result[:lf]).to eq(1)
  end

  it "correctly merges three sources with overlapping and disjoint files" do
    a = raw(hit_map: { "a.rb" => { "1" => 1 } }, lf: 1, lh: 1)
    b = raw(hit_map: { "a.rb" => { "1" => 2 }, "b.rb" => { "3" => 5 } }, lf: 3, lh: 2)
    c = raw(hit_map: { "b.rb" => { "3" => 0 }, "c.rb" => { "7" => 1 } }, lf: 2, lh: 1)

    result = merge(a, b, c)
    expect(result[:hit_map]["a.rb"]["1"]).to eq(3)
    expect(result[:hit_map]["b.rb"]["3"]).to eq(5)
    expect(result[:hit_map]["c.rb"]["7"]).to eq(1)
    expect(result[:lf]).to eq(6)
    expect(result[:lh]).to eq(4)
  end
end
