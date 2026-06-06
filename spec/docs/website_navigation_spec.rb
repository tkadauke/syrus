require "rails_helper"

RSpec.describe "Website navigation and metadata" do
  WEBSITE_ROOT = Rails.root.join("website")
  MARKDOWN_GLOBS = [
    "src/pages/**/*.md",
    "src/content/docs/**/*.md"
  ].freeze

  def markdown_files
    MARKDOWN_GLOBS.flat_map { |glob| WEBSITE_ROOT.glob(glob) }.sort_by(&:to_s)
  end

  def frontmatter_for(path)
    match = path.read.match(/\A---\n(?<yaml>.*?)\n---\n/m)
    raise "Missing frontmatter in #{path}" unless match

    YAML.safe_load(match[:yaml])
  end

  def route_for(path)
    relative = path.relative_path_from(WEBSITE_ROOT.join("src")).to_s

    case relative
    when %r{\Apages/index\.md\z}
      "/"
    when %r{\Apages/(.+)\.md\z}
      "/#{$1}"
    when %r{\Acontent/docs/index\.md\z}
      "/docs"
    when %r{\Acontent/docs/(.+)/index\.md\z}
      "/docs/#{$1}"
    when %r{\Acontent/docs/(.+)\.md\z}
      "/docs/#{$1}"
    else
      raise "Unknown website route for #{path}"
    end
  end

  def route_map
    markdown_files.to_h { |path| [route_for(path), path] }
  end

  def internal_markdown_links(path)
    path.read.scan(/\[[^\]]+\]\(([^)]+)\)/).flatten.filter_map do |href|
      next if href.start_with?("http://", "https://", "mailto:")
      next if href.start_with?("#")

      href.split(/[ \t\n]/).first
    end
  end

  def anchor_slugs(path)
    path.read.scan(/^\#{1,6}\s+(.+)$/).flatten.map do |heading|
      heading
        .gsub(/`([^`]*)`/, "\\1")
        .downcase
        .gsub(/[^a-z0-9\s-]/, "")
        .strip
        .gsub(/\s+/, "-")
    end
  end

  def internal_navigation_urls
    site_config = YAML.safe_load(WEBSITE_ROOT.join("src/site.yml").read)
    primary = site_config.fetch("navigation").fetch("primary").map { |item| item.fetch("url") }
    footer = site_config.fetch("navigation").fetch("footer").flat_map do |group|
      group.fetch("links").map { |item| item.fetch("url") }
    end

    (primary + footer).reject { |url| url.start_with?("http://", "https://", "mailto:") }
  end

  it "keeps page title and description frontmatter on every markdown route" do
    markdown_files.each do |path|
      metadata = frontmatter_for(path)

      expect(metadata["title"]).to be_present, "#{path} needs a title"
      expect(metadata["description"]).to be_present, "#{path} needs a description"
      expect(metadata["description"].length).to be_between(40, 170), "#{path} description should be useful for SEO snippets"
    end
  end

  it "keeps central site metadata and navigation release-ready" do
    site_config = YAML.safe_load(WEBSITE_ROOT.join("src/site.yml").read)
    site = site_config.fetch("site")

    expect(site.fetch("name")).to eq("Syrus")
    expect(site.fetch("url")).to match(%r{\Ahttps://})
    expect(site.fetch("title_template")).to include("%s")
    expect(site.fetch("description")).to be_present
    expect(site.fetch("social").fetch("title")).to be_present
    expect(site.fetch("social").fetch("description")).to be_present

    primary_labels = site_config.fetch("navigation").fetch("primary").map { |item| item.fetch("label") }
    expect(primary_labels).to eq(["Home", "What is Syrus?", "Why use Syrus?", "Getting Started", "Docs"])
  end

  it "points configured navigation at real routes" do
    routes = route_map.keys

    internal_navigation_urls.each do |url|
      expect(routes).to include(url), "Configured navigation points at missing route #{url}"
    end
  end

  it "keeps markdown internal links and hash anchors resolvable" do
    routes = route_map

    markdown_files.each do |path|
      internal_markdown_links(path).each do |href|
        target_route, target_anchor = href.split("#", 2)
        target_route = "/" if target_route.blank?

        expect(routes).to include(target_route), "#{path} links to missing route #{href}"

        next if target_anchor.blank?

        expect(anchor_slugs(routes.fetch(target_route))).to include(target_anchor), "#{path} links to missing anchor #{href}"
      end
    end
  end

  it "keeps every page connected to another internal route" do
    markdown_files.each do |path|
      links = internal_markdown_links(path).map { |href| href.split("#", 2).first.presence || route_for(path) }
      expect(links.uniq.any? { |link| link != route_for(path) }).to be(true), "#{path} should link onward"
    end
  end

  it "does not resurrect the removed /evaluate route" do
    all_website_text = markdown_files.map(&:read).join("\n")

    expect(all_website_text).not_to include("](/evaluate")
  end
end
