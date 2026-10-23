# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website locale routing" do
  def read_website(path)
    File.read(File.expand_path("../../website/#{path}", __dir__))
  end

  it "threads locale through shared components that render internal links" do
    components = %w[
      nav.tsx
      footer.tsx
      docs-page.tsx
      download-cta.tsx
      hero.tsx
      demo.tsx
      features.tsx
      plugin-directory.tsx
    ]

    components.each do |component|
      source = read_website("components/#{component}")

      expect(source).to include("type Locale"), "expected #{component} to accept a typed locale"
      expect(source).to include("localizedHref"), "expected #{component} to localize internal links"
    end
  end

  it "checks the language of every HTML document in the static export" do
    assertion = read_website("scripts/assert-static-export.ts")

    expect(assertion).to include("htmlFiles(output)")
    expect(assertion).to include('lang="${expectedLocale}"')
    expect(assertion).to include('path.join(output, "de")')
    expect(assertion).to include('path.join(output, "la")')
    expect(read_website("src/app/global-not-found.tsx")).to include('<html lang="en">')
  end
end
