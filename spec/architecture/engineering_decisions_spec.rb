# frozen_string_literal: true

require "yaml"
require "date"

RSpec.describe "engineering decision records" do
  let(:root) { Pathname.new(File.expand_path("../..", __dir__)) }
  let(:decisions_root) { root.join("docs/engineering/decisions") }
  let(:index) { decisions_root.join("README.md").read }
  let(:non_record_filenames) { %w[README.md TEMPLATE.md] }
  let(:record_paths) do
    decisions_root.glob("*.md").reject do |path|
      non_record_filenames.include?(path.basename.to_s)
    end.sort
  end
  let(:records) { record_paths.to_h { |path| [ path, metadata(path) ] } }

  it "uses stable filenames and matching unique identifiers" do
    ids = records.map do |path, attributes|
      number = path.basename.to_s.match(/\A(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md\z/)&.captures&.first

      expect(number).not_to be_nil, "invalid ADR filename: #{path.relative_path_from(root)}"
      expect(attributes["id"]).to eq("ADR-#{number}")
      attributes["id"]
    end

    expect(ids).not_to be_empty
    expect(ids).to eq(ids.uniq), "ADR identifiers must be unique"
  end

  it "retains every allocated record below the documented next identifier" do
    next_number = index.match(/next available identifier is `ADR-(\d{4})`/)&.captures&.first
    expect(next_number).not_to be_nil, "decision index must document the next available ADR identifier"

    allocated_numbers = records.values.map { |attributes| attributes.fetch("id").delete_prefix("ADR-").to_i }
    expect(allocated_numbers.sort).to eq((1...next_number.to_i).to_a),
      "allocated ADR identifiers and files must remain present forever"
  end

  it "requires complete lifecycle metadata" do
    records.each do |path, attributes|
      expect(attributes.keys).to contain_exactly(
        "id", "title", "status", "date", "supersedes", "superseded_by"
      ), "invalid metadata keys in #{path.relative_path_from(root)}"
      expect(attributes["title"]).to be_a(String)
      expect(attributes["title"]).not_to be_empty
      expect(attributes["date"]).to match(/\A\d{4}-\d{2}-\d{2}\z/)
      expect { Date.iso8601(attributes["date"]) }.not_to raise_error
      expect(%w[proposed accepted superseded retired]).to include(attributes["status"])
      expect(attributes["supersedes"]).to be_an(Array)
      expect(attributes["superseded_by"]).to be_an(Array)
      expect(attributes.values_at("supersedes", "superseded_by").flatten).to all(match(/\AADR-\d{4}\z/))

      if attributes["status"] == "superseded"
        expect(attributes["superseded_by"]).not_to be_empty
      else
        expect(attributes["superseded_by"]).to be_empty
      end
    end
  end

  it "indexes every decision record exactly once" do
    records.each_value do |attributes|
      expect(index.scan(/\[#{Regexp.escape(attributes.fetch("id"))}\]\([^)]+\)/).size).to eq(1)
    end

    indexed_ids = index.scan(/\[(ADR-\d{4})\]\([^)]+\)/).flatten
    expect(indexed_ids.sort).to eq(records.values.map { |attributes| attributes.fetch("id") }.sort)
  end

  it "keeps accepted records focused on durable rationale and evidence" do
    records.each do |path, attributes|
      next unless attributes.fetch("status") == "accepted"

      body = path.read.sub(/\A---\s*\n.*?\n---\s*\n/m, "")
      headings = body.scan(/^## (.+)$/).flatten

      expect(headings).to eq(%w[Context Decision Consequences Evidence]),
        "unexpected accepted-record sections in #{path.relative_path_from(root)}"
      expect(body.scan(/^- \[[^\]]+\]\([^)]+\)$/).size).to be >= 2,
        "accepted ADRs need at least two durable evidence links in #{path.relative_path_from(root)}"
    end
  end

  it "keeps supersession links valid and reciprocal" do
    records_by_id = records.values.to_h { |attributes| [ attributes.fetch("id"), attributes ] }

    records_by_id.each do |id, attributes|
      %w[supersedes superseded_by].each do |relationship|
        expect(attributes.fetch(relationship)).to eq(attributes.fetch(relationship).uniq)

        attributes.fetch(relationship).each do |related_id|
          expect(related_id).not_to eq(id)
          expect(records_by_id).to have_key(related_id), "#{id} links to missing #{related_id}"

          inverse = relationship == "supersedes" ? "superseded_by" : "supersedes"
          expect(records_by_id.fetch(related_id).fetch(inverse)).to include(id)
          if relationship == "supersedes"
            expect(attributes.fetch("status")).to eq("accepted")
            expect(records_by_id.fetch(related_id).fetch("status")).to eq("superseded")
          end
        end
      end
    end
  end

  def metadata(path)
    front_matter = path.read.match(/\A---\s*\n(.*?)\n---\s*\n/m)&.captures&.first
    raise "missing YAML front matter in #{path.relative_path_from(root)}" unless front_matter

    YAML.safe_load(front_matter, permitted_classes: [], aliases: false)
  end
end
