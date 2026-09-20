require "rails_helper"
require "json"
require "tmpdir"

RSpec.describe JavaScript::GradeDetector do
  around do |example|
    Dir.mktmpdir("syrus-javascript-grade-detector") { |dir| @dir = dir; example.run }
  end

  it "detects vitest from package dependencies" do
    write("package.json", JSON.generate("devDependencies" => { "vitest" => "^4.0.0" }))

    candidate = described_class.grade_candidates(@dir).first

    expect(candidate).to include(
      name: "vitest",
      run: "type: vitest",
      type: "vitest",
      evidence: "package.json dependencies"
    )
  end

  it "detects vitest from package scripts" do
    write("package.json", JSON.generate("scripts" => { "test" => "vitest run" }))

    expect(described_class.grade_candidates(@dir).first[:evidence]).to eq("package.json scripts")
  end

  it "detects vitest config files" do
    write("vitest.config.ts", "")

    expect(described_class.grade_candidates(@dir).first[:evidence]).to eq("vitest.config.ts")
  end

  it "declines repositories without vitest signals" do
    write("package.json", JSON.generate("scripts" => { "test" => "jest" }))

    expect(described_class.grade_candidates(@dir)).to eq([])
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
