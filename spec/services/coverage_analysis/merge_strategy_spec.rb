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

  it "recomputes lf/lh totals from the merged hit map" do
    a = raw(hit_map: { "app/foo.rb" => { "1" => 1, "2" => 0 } }, lf: 100, lh: 100)
    b = raw(hit_map: { "app/foo.rb" => { "2" => 2, "3" => 0 } }, lf: 100, lh: 100)

    result = merge(a, b)
    expect(result[:lf]).to eq(3)
    expect(result[:lh]).to eq(2)
  end

  it "preserves weighted coverage units while using their lines for the hit map" do
    source = raw(
      hit_map: { "pkg/a.go" => { "1" => 1, "3" => 0, "4" => 0, "5" => 0 } },
      file_stats: { "pkg/a.go" => { lf: 5, lh: 4, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    ).merge(
      coverage_units: {
        "pkg/a.go" => {
          "1.1,1.20" => { statements: 4, hits: 1 },
          "3.1,5.2" => { statements: 1, hits: 0 }
        }
      }
    )

    result = merge(source)

    expect(result).to include(lf: 5, lh: 4)
    expect(result[:file_stats]["pkg/a.go"]).to include(lf: 5, lh: 4)
  end

  it "deduplicates matching weighted coverage units across sources" do
    unit = {
      hit_map: { "pkg/a.go" => { "1" => 1 } },
      lf: 3, lh: 3, brf: 0, brh: 0, fnf: 0, fnh: 0,
      file_stats: { "pkg/a.go" => { lf: 3, lh: 3, brf: 0, brh: 0, fnf: 0, fnh: 0 } },
      coverage_units: { "pkg/a.go" => { "1.1,1.20" => { statements: 3, hits: 1 } } }
    }

    result = merge(unit, unit)

    expect(result).to include(lf: 3, lh: 3)
    expect(result[:coverage_units]["pkg/a.go"]["1.1,1.20"][:hits]).to eq(2)
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

  it "recomputes per-file line stats from the merged hit map while summing branch and function fields" do
    stats_a = { lf: 10, lh: 7, brf: 4, brh: 2, fnf: 1, fnh: 1 }
    stats_b = { lf: 5,  lh: 5, brf: 2, brh: 2, fnf: 1, fnh: 0 }

    a = raw(
      hit_map: { "app/foo.rb" => { "1" => 1, "2" => 0 } },
      file_stats: { "app/foo.rb" => stats_a }
    )
    b = raw(
      hit_map: { "app/foo.rb" => { "2" => 3, "3" => 0 } },
      file_stats: { "app/foo.rb" => stats_b }
    )

    result = merge(a, b)
    merged_stats = result[:file_stats]["app/foo.rb"]
    expect(merged_stats).to eq({ lf: 3, lh: 2, brf: 6, brh: 4, fnf: 2, fnh: 1 })
  end

  it "handles a nil or missing hit_map key without raising" do
    a = raw(hit_map: nil, file_stats: nil)
    b = raw(hit_map: { "app/foo.rb" => { "1" => 1 } }, lf: 1, lh: 1)

    result = merge(a, b)
    expect(result[:hit_map]).to eq({ "app/foo.rb" => { "1" => 1 } })
    expect(result[:lf]).to eq(1)
  end

  it "does not preserve line stats that are missing from the merged hit map" do
    source = raw(
      file_stats: { "app/foo.rb" => { lf: 10, lh: 8, brf: 2, brh: 1, fnf: 0, fnh: 0 } },
      brf: 2,
      brh: 1
    )

    result = merge(source)

    expect(result[:lf]).to eq(0)
    expect(result[:lh]).to eq(0)
    expect(result[:file_stats]["app/foo.rb"]).to include(lf: 0, lh: 0, brf: 2, brh: 1)
  end

  it "correctly merges three sources with overlapping and disjoint files" do
    a = raw(hit_map: { "a.rb" => { "1" => 1 } }, lf: 1, lh: 1)
    b = raw(hit_map: { "a.rb" => { "1" => 2 }, "b.rb" => { "3" => 5 } }, lf: 3, lh: 2)
    c = raw(hit_map: { "b.rb" => { "3" => 0 }, "c.rb" => { "7" => 1 } }, lf: 2, lh: 1)

    result = merge(a, b, c)
    expect(result[:hit_map]["a.rb"]["1"]).to eq(3)
    expect(result[:hit_map]["b.rb"]["3"]).to eq(5)
    expect(result[:hit_map]["c.rb"]["7"]).to eq(1)
    expect(result[:lf]).to eq(3)
    expect(result[:lh]).to eq(3)
  end

  it "normalizes disjoint partial coverage for the same file as fully covered" do
    unit = raw(
      hit_map: { "app/foo.rb" => { "1" => 1, "2" => 0 } },
      lf: 2,
      lh: 1,
      file_stats: { "app/foo.rb" => { lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    )
    integration = raw(
      hit_map: { "app/foo.rb" => { "1" => 0, "2" => 1 } },
      lf: 2,
      lh: 1,
      file_stats: { "app/foo.rb" => { lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    )

    normalized = CoverageAnalysis::Normalizer.normalize(merge(unit, integration))

    expect(normalized[:summary]["lines_pct"]).to eq(100.0)
    expect(normalized[:files]["app/foo.rb"]).to include(
      "lines_pct" => 100.0,
      "line_count" => 2,
      "covered_line_count" => 2
    )
  end

  it "counts overlapping executable lines once when deriving normalized percentages" do
    first = raw(
      hit_map: { "app/foo.rb" => { "1" => 1, "2" => 0 } },
      lf: 2,
      lh: 1,
      file_stats: { "app/foo.rb" => { lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    )
    second = raw(
      hit_map: { "app/foo.rb" => { "2" => 3, "3" => 0 } },
      lf: 2,
      lh: 1,
      file_stats: { "app/foo.rb" => { lf: 2, lh: 1, brf: 0, brh: 0, fnf: 0, fnh: 0 } }
    )

    normalized = CoverageAnalysis::Normalizer.normalize(merge(first, second))

    expect(normalized[:summary]["lines_pct"]).to eq(66.67)
    expect(normalized[:files]["app/foo.rb"]).to include(
      "lines_pct" => 66.67,
      "line_count" => 3,
      "covered_line_count" => 2
    )
  end
end
