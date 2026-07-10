require "rails_helper"

RSpec.describe Coverage::Parsers::Lcov do
  def parse(content)
    described_class.parse(content)
  end

  it "parses a simple LCOV trace file into a hit map" do
    result = parse(<<~LCOV)
      TN:
      SF:app/models/user.rb
      DA:1,5
      DA:2,0
      DA:3,3
      LF:3
      LH:2
      BRF:4
      BRH:2
      FNF:1
      FNH:1
      end_of_record
    LCOV

    expect(result.raw[:hit_map]).to eq({
      "app/models/user.rb" => { "1" => 5, "2" => 0, "3" => 3 }
    })
    expect(result.raw[:lf]).to eq(3)
    expect(result.raw[:lh]).to eq(2)
    expect(result.raw[:brf]).to eq(4)
    expect(result.raw[:brh]).to eq(2)
    expect(result.raw[:fnf]).to eq(1)
    expect(result.raw[:fnh]).to eq(1)
    expect(result.lines_pct).to eq(66.67)
  end

  it "handles multiple source files" do
    result = parse(<<~LCOV)
      SF:app/models/user.rb
      DA:1,1
      LF:1
      LH:1
      end_of_record
      SF:app/models/post.rb
      DA:1,0
      DA:2,0
      LF:2
      LH:0
      end_of_record
    LCOV

    expect(result.raw[:hit_map].keys).to contain_exactly("app/models/user.rb", "app/models/post.rb")
    expect(result.raw[:lf]).to eq(3)
    expect(result.raw[:lh]).to eq(1)
    expect(result.lines_pct).to eq(33.33)
  end

  it "returns empty results for empty input" do
    result = parse("")
    expect(result.raw[:hit_map]).to be_empty
    expect(result.raw[:lf]).to eq(0)
    expect(result.lines_pct).to be_nil
  end
end
