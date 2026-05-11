# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website about page" do
  subject(:content) { File.read(File.expand_path("../../website/src/pages/about.md", __dir__)) }

  let(:normalized_content) { content.gsub(/\s+/, " ") }

  it "emphasizes Publilius Syrus as a durable writer before historical context" do
    expect(content).to include("1st-century-BCE Roman writer")
    expect(content).to include("schoolbook material for more than a millennium")
    expect(normalized_content).to include("legal, moral, and common-sense English still quote")
    expect(content).to include("two thousand years later")
    expect(content).to include("small, durable text that compounds")

    writer_index = content.index("Roman writer")
    enslaved_index = content.index("enslaved")

    expect(writer_index).to be < enslaved_index
  end

  it "mentions his famous maxims and the traditional account of his manumission" do
    expect(normalized_content).to include("Phrases he coined, or that are commonly credited to him")
    expect(content).to include("honor among thieves")
    expect(normalized_content).to include("the end justifies the means")
    expect(content).to include("necessity knows no law")
    expect(normalized_content).to include("a rolling stone gathers no moss")
    expect(normalized_content).to include("his wit and genius caught the attention of his master")
    expect(normalized_content).to include("educated him and freed him")
  end
end
