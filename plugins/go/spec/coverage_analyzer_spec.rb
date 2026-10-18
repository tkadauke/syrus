require "rails_helper"

RSpec.describe Go::CoverageAnalyzer do
  def fixture(name)
    Pathname.new(__dir__).join("fixtures/coverage", name)
  end

  def parse(name, format: "go-cover")
    described_class.call(artifact_path: fixture(name), format_hint: format)
  end

  it "declines artifacts not explicitly configured as go-cover" do
    expect(parse("count.out", format: "lcov")).to be_nil
  end

  it "maps multiple packages, zero-count blocks, and overlapping blocks into line hits" do
    result = parse("count.out")

    expect(result.raw[:hit_map]).to eq(
      "example.com/acme/pkg/math.go" => {
        "3" => 4, "4" => 4, "5" => 7, "6" => 0
      },
      "example.com/acme/cmd/tool/main.go" => { "10" => 0 }
    )
    expect(result.raw[:file_stats]["example.com/acme/pkg/math.go"]).to include(lf: 4, lh: 3)
    expect(result.raw).to include(lf: 5, lh: 3)
    expect(result.lines_pct).to eq(60.0)
  end

  it "normalizes Windows separators and preserves module-relative paths" do
    result = parse("windows.out")

    expect(result.raw[:hit_map]).to eq(
      "C:/work/acme/internal/worker.go" => { "7" => 5, "8" => 5 },
      "./pkg/helper.go" => { "2" => 1 }
    )
    expect(result.lines_pct).to eq(100.0)
  end

  it "supports set mode without inflating overlapping hits" do
    file = Tempfile.new("go-cover")
    file.write("mode: set\npkg/a.go:1.1,1.5 1 1\npkg/a.go:1.2,1.6 1 8\n")
    file.close

    result = described_class.call(artifact_path: Pathname.new(file.path), format_hint: "go-cover")

    expect(result.raw[:hit_map]).to eq("pkg/a.go" => { "1" => 1 })
  ensure
    file&.unlink
  end

  it "weights aggregate coverage by native statement counts rather than spanned lines" do
    file = Tempfile.new("go-cover")
    file.write(<<~COVERAGE)
      mode: count
      pkg/a.go:1.1,1.20 4 1
      pkg/a.go:3.1,8.2 1 0
    COVERAGE
    file.close

    result = described_class.call(artifact_path: Pathname.new(file.path), format_hint: "go-cover")

    expect(result.raw).to include(lf: 5, lh: 4)
    expect(result.raw[:file_stats]["pkg/a.go"]).to include(lf: 5, lh: 4)
    expect(result.lines_pct).to eq(80.0)
    expect(result.raw[:hit_map]["pkg/a.go"].size).to eq(7)
  ensure
    file&.unlink
  end

  it "resolves module-qualified paths from the nearest go.mod" do
    Dir.mktmpdir("go-cover-module") do |dir|
      root = Pathname.new(dir)
      root.join("go.mod").write("module example.com/acme\n")
      profile = root.join("tmp/coverage.out")
      profile.dirname.mkpath
      profile.write("mode: set\nexample.com/acme/pkg/a.go:2.1,2.5 1 1\n")

      result = described_class.call(artifact_path: profile, format_hint: "go-cover")

      expect(result.raw[:hit_map]).to have_key(root.join("pkg/a.go").to_s)
    end
  end

  it "returns an empty result for a header-only profile" do
    file = Tempfile.new("go-cover")
    file.write("mode: count\n")
    file.close

    result = described_class.call(artifact_path: Pathname.new(file.path), format_hint: "go-cover")

    expect(result.raw[:hit_map]).to be_empty
    expect(result.lines_pct).to be_nil
  ensure
    file&.unlink
  end

  it "rejects malformed and unsupported headers" do
    aggregate_failures do
      expect { described_class.new("").parse }.to raise_error(ArgumentError, /profile header/)
      expect { described_class.new("mode: mystery\n").parse }.to raise_error(ArgumentError, /unsupported.*mode/)
    end
  end

  it "rejects malformed records with their profile line number" do
    expect {
      described_class.new("mode: atomic\nnot a coverage record\n").parse
    }.to raise_error(ArgumentError, /record on line 2/)
  end
end
