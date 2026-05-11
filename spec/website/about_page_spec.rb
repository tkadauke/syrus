# frozen_string_literal: true

require "rails_helper"

RSpec.describe "website about page" do
  subject(:content) { Rails.root.join("website/src/pages/about.md").read }

  it "covers the naming story with the writer framing first" do
    expect(content).to include("Publilius Syrus")
    expect(content).to include("1st-century-BCE Roman writer")
    expect(content).to include("schoolbook material")
    expect(content).to include("two thousand years")
    expect(content).to include("small, durable text that compounds")

    writer_index = content.index("Roman writer")
    enslaved_index = content.index("enslaved")
    expect(writer_index).to be < enslaved_index
  end

  it "covers the project history and recursion" do
    expect(content).to include("sketched on a plane on May 1, 2026")
    expect(content).to match(/created as a repository\s+that same evening/)
    expect(content).to include("By day two")
    expect(content).to match(/The auto-rebase feature was\s+itself shipped through Syrus running auto-rebase/)
    expect(content).to include("The public website was planned as Syrus jobs")
  end

  it "provides contact, concepts, and footer links" do
    expect(content).to include("[the concepts guide](/docs/concepts)")
    expect(content).to include("[Thomas Kadauke](https://github.com/tkadauke)")
    expect(content).to include("@tkadauke")
    expect(content).to include("[Back to home](/)")
    expect(content).to include("[GitHub](https://github.com/tkadauke/syrus)")
    expect(content).to include("[Try Syrus locally](/evaluate)")
  end
end
