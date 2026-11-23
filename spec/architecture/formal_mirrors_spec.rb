require "rails_helper"
require "tmpdir"
require Rails.root.join("lib/syrus/formal_mirrors")

# Drift detection for the Lean models (formal/INTEGRATION.md, layer 2): when a
# Ruby method a model mirrors changes, the model may no longer describe the
# code. Review the model in the same change, then run
# `bin/formal-mirrors --update` to record the new hash.
RSpec.describe "Lean model mirrors" do
  let(:root) { Rails.root }
  let(:mirrors) { Syrus::FormalMirrors.mirrors(root) }

  it "names only models that exist" do
    missing = mirrors.map(&:model).uniq.reject { |model| root.join("formal/SyrusModel", model).file? }

    expect(missing).to be_empty, "formal/mirrors.yml names models that do not exist: #{missing.join(', ')}"
  end

  it "matches every mirrored method's source" do
    stale = mirrors.filter_map do |mirror|
      current = Syrus::FormalMirrors.current_sha(root, mirror)
      next if current && current == mirror.sha

      "#{mirror.model} may be stale: #{mirror.label} #{current ? 'changed' : 'was not found'}"
    end

    expect(stale).to be_empty, <<~MESSAGE
      #{stale.join("\n")}
      Review each model against the changed method, update it if the behaviour it describes changed,
      then run bin/formal-mirrors --update.
    MESSAGE
  end

  describe Syrus::FormalMirrors do
    around do |example|
      Dir.mktmpdir do |dir|
        @dir = Pathname.new(dir)
        @dir.join("formal").mkpath
        @dir.join("app").mkpath
        example.run
      end
    end

    def write_source(body)
      @dir.join("app/widget.rb").write(<<~RUBY)
        module Outer
          class Widget
            def spin = #{body}
            def self.make = new
          end
          class Other
            def spin = :other
          end
        end
      RUBY
    end

    def write_manifest(sha: nil, method: "spin", owner: "Widget")
      @dir.join("formal/mirrors.yml").write({ "models" => [ { "model" => "Widget.lean", "mirrors" => [
        { "path" => "app/widget.rb", "owner" => owner, "method" => method, "sha" => sha }.compact
      ] } ] }.to_yaml)
    end

    it "detects a change to the mirrored method and records the new hash on update" do
      write_source(":fast")
      write_manifest
      described_class.update!(@dir)
      recorded = described_class.mirrors(@dir).first.sha

      write_source(":slow")
      expect(described_class.current_sha(@dir, described_class.mirrors(@dir).first)).not_to eq(recorded)

      expect(described_class.update!(@dir).map(&:method)).to eq([ "spin" ])
      expect(described_class.current_sha(@dir, described_class.mirrors(@dir).first)).to eq(described_class.mirrors(@dir).first.sha)
    end

    it "picks the method of the named class, not a same-named one elsewhere" do
      write_source(":fast")
      write_manifest
      widget = described_class.current_sha(@dir, described_class.mirrors(@dir).first)
      write_manifest(owner: "Other")

      expect(described_class.current_sha(@dir, described_class.mirrors(@dir).first)).not_to eq(widget)
    end

    it "finds singleton methods by a self. prefix" do
      write_source(":fast")
      write_manifest(method: "self.make")

      expect(described_class.current_sha(@dir, described_class.mirrors(@dir).first)).to be_present
    end

    it "reports a mirrored method that no longer exists" do
      write_source(":fast")
      write_manifest(method: "renamed")

      expect(described_class.current_sha(@dir, described_class.mirrors(@dir).first)).to be_nil
      expect { described_class.update!(@dir) }.to raise_error(ArgumentError, /not found/)
    end
  end
end
