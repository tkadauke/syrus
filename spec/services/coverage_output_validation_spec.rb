require "rails_helper"
require "tmpdir"

RSpec.describe CoverageOutputValidation do
  around do |example|
    Dir.mktmpdir("coverage-output-validation") do |directory|
      @directory = Pathname(directory)
      example.run
    end
  end

  def validate(format, filename, content)
    path = @directory.join(filename)
    path.write(content)
    described_class::Base.for(format).validate(path)
  end

  describe ".for" do
    it "returns the validator for each supported format" do
      expect(described_class::Base.for(:lcov)).to be_a(described_class::Lcov)
      expect(described_class::Base.for("cobertura")).to be_a(described_class::Cobertura)
      expect(described_class::Base.for("go-cover")).to be_a(described_class::GoCover)
      expect(described_class::Base.for("simplecov")).to be_a(described_class::SimpleCov)
    end

    it "returns nil for an unsupported format" do
      expect(described_class::Base.for("unknown")).to be_nil
    end
  end

  describe "format validation" do
    it "accepts coverage-shaped files for every supported format" do
      results = [
        validate("lcov", "coverage.info", "TN:\nSF:app/models/user.rb\nDA:1,1\nend_of_record\n"),
        validate("cobertura", "coverage.xml", %(<?xml version="1.0"?><coverage line-rate="1"></coverage>)),
        validate("go-cover", "coverage.out", "mode: atomic\nexample.go:1.1,2.1 1 1\n"),
        validate("simplecov", ".resultset.json", '{"RSpec":{"coverage":{"app/models/user.rb":[1]}}}')
      ]

      expect(results).to all(be_valid)
      expect(results.map(&:reason)).to all(be_nil)
    end

    it "rejects empty files before inspecting their names or content" do
      result = validate("lcov", "not-coverage.txt", "")

      expect(result).not_to be_valid
      expect(result.reason).to eq("file is empty")
    end

    it "rejects a filename that does not match its declared format" do
      result = validate("cobertura", "coverage.json", "<coverage></coverage>")

      expect(result).not_to be_valid
      expect(result.reason).to eq("filename is not valid for cobertura")
    end

    it "rejects content that does not match its declared format" do
      results = [
        validate("lcov", "coverage.info", "SF:app/models/user.rb\n"),
        validate("cobertura", "coverage.xml", "<report></report>"),
        validate("go-cover", "coverage.cov", "example.go:1.1,2.1 1 1\n"),
        validate("simplecov", ".resultset.json", '{"RSpec":{"timestamp":123}}'),
        validate("simplecov", ".resultset.json", "not json")
      ]

      expect(results).to all(satisfy { |result| !result.valid? })
      expect(results.map(&:reason)).to eq([
        "content is not valid for lcov",
        "content is not valid for cobertura",
        "content is not valid for go-cover",
        "content is not valid for simplecov",
        "content is not valid for simplecov"
      ])
    end
  end
end
