# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website Publilius Syrus references" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  let(:site_copy) { read_website("lib/site.ts") }
  let(:hero) { read_website("components/hero.tsx") }
  let(:footer) { read_website("components/footer.tsx") }

  it "keeps the Publilius Syrus quote and attribution in the site copy" do
    expect(site_copy).to include("Bis dat qui cito dat.")
    expect(site_copy).to include("He gives twice who gives quickly.")
    expect(site_copy).to include("Publilius Syrus")
  end

  it "renders the quote on the landing page surfaces" do
    expect(hero).to include("copy.taglineTranslation")
    expect(hero).to include("site.taglineAttribution")
    expect(footer).to include("site.tagline")
  end
end
