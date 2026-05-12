require "rails_helper"

RSpec.describe JobDependencyParser do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets") }

  def refs(text)
    described_class.parse(text: text, default_repository: repository).map do |ref|
      [ ref.owner, ref.repo, ref.number ]
    end
  end

  it "parses a single issue reference" do
    expect(refs("Depends-on: #42")).to eq([ [ "acme", "widgets", 42 ] ])
  end

  it "parses comma-separated references" do
    expect(refs("Depends-on: #43, #44")).to eq([
      [ "acme", "widgets", 43 ],
      [ "acme", "widgets", 44 ]
    ])
  end

  it "unions multiple dependency lines and synonyms" do
    expect(refs("Depends on: #1\nBlocked-by: #2\nblocked by: #3")).to eq([
      [ "acme", "widgets", 1 ],
      [ "acme", "widgets", 2 ],
      [ "acme", "widgets", 3 ]
    ])
  end

  it "parses owner/repo-prefixed references" do
    expect(refs("Depends-on: tkadauke/raytracer#102")).to eq([
      [ "tkadauke", "raytracer", 102 ]
    ])
  end

  it "ignores malformed lines gracefully" do
    expect(refs("Depends-on: tomorrow\nBlocks: #9\nDepends-on: acme/widgets")).to eq([])
  end
end
