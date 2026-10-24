# frozen_string_literal: true

require "spec_helper"

# Every image the site and the README point at must actually be in
# website/public. Removing a screenshot is a two-place edit -- the gallery entry
# AND whatever else references the file -- and nothing caught the second place:
# a deleted screenshot stayed wired up as the product video's `poster` and as
# the README's hero badge, both of which fail silently (a broken poster just
# renders blank, and GitHub shows a broken image).
RSpec.describe "website public asset references" do
  REPO_ROOT = File.expand_path("../..", __dir__)
  PUBLIC_DIR = File.join(REPO_ROOT, "website/public")

  # Local absolute asset paths only: "/media/x.png", "/product-screenshot.png".
  # Skips http(s), protocol-relative, and Next route paths without an extension.
  ASSET_REFERENCE = %r{["'(](/[\w./-]+\.(?:png|jpe?g|webp|avif|svg|mp4|webm|vtt|ico))["')]}

  def component_sources
    Dir.glob(File.join(REPO_ROOT, "website/{components,src}/**/*.{ts,tsx}"))
      .reject { |path| path.include?("/node_modules/") }
  end

  it "resolves every asset path referenced by a website component" do
    missing = component_sources.flat_map do |path|
      File.read(path, encoding: "UTF-8").scan(ASSET_REFERENCE).flatten.uniq.filter_map do |ref|
        next if File.exist?(File.join(PUBLIC_DIR, ref.delete_prefix("/")))

        "#{path.delete_prefix("#{REPO_ROOT}/")} -> #{ref}"
      end
    end

    expect(missing).to be_empty, "components reference assets that are not in website/public:\n  #{missing.join("\n  ")}"
  end

  # The same failure one layer up: this example's sibling asserted that calls to
  # action "use real current anchors", but it only string-matched the hrefs --
  # so when a homepage section was removed, three CTAs kept pointing at an
  # anchor that no longer rendered anywhere and nothing failed.
  it "resolves every homepage fragment link to a section that renders that id" do
    sources = component_sources
    ids = sources.flat_map { |path| File.read(path, encoding: "UTF-8").scan(/id="([\w-]+)"/).flatten }
    ids += %w[main]  # <main id="main"> lives in the page, not a component
    ids.uniq!

    dangling = sources.flat_map do |path|
      File.read(path, encoding: "UTF-8").scan(%r{href(?:=|: )["']/#([\w-]+)["']}).flatten.uniq.filter_map do |anchor|
        next if ids.include?(anchor)

        "#{path.delete_prefix("#{REPO_ROOT}/")} -> /##{anchor}"
      end
    end

    expect(dangling).to be_empty, "components link to homepage anchors that no section renders:\n  #{dangling.join("\n  ")}"
  end

  it "resolves every repo-relative website image the README embeds" do
    readme = File.read(File.join(REPO_ROOT, "README.md"), encoding: "UTF-8")
    refs = readme.scan(%r{\((website/public/[\w./-]+\.(?:png|jpe?g|webp|avif|svg))\)}).flatten.uniq

    expect(refs).not_to be_empty, "expected the README to embed at least one website image"
    missing = refs.reject { |ref| File.exist?(File.join(REPO_ROOT, ref)) }
    expect(missing).to be_empty, "README embeds missing images: #{missing.join(", ")}"
  end
end
