require "rails_helper"

# Bundler evaluates every plugin gemspec during `bundle install`. In the Docker
# build that happens long before `COPY . .`, so anything a gemspec
# require_relatives outside its own plugin has to be copied in first.
#
# The failure this prevents is Docker-only and invisible locally: the working
# tree has all of lib/, so the gemspecs load fine, `bin/rspec` is green, and the
# image build dies with `cannot load such file -- /rails/lib/syrus/plugin_gemspec`.
# Introducing the shared `Syrus.plugin_gemspec` helper broke the image exactly
# this way.
RSpec.describe "plugin gemspec requires in the Docker build" do
  GEMSPECS = Dir[Rails.root.join("plugins/*/*.gemspec")]
  DOCKERFILE = Rails.root.join("Dockerfile")

  # Everything COPYed into the image before `bundle install` runs.
  def paths_copied_before_bundle_install
    lines = File.readlines(DOCKERFILE)
    cutoff = lines.index { |line| line.match?(/^RUN\s+bundle install\b/) }
    raise "no `RUN bundle install` in the Dockerfile" if cutoff.nil?

    lines.first(cutoff).filter_map do |line|
      match = line.match(/^COPY\s+(?:--\S+\s+)*(.+?)\s+\S+\s*$/)
      match && match[1].split(/\s+/)
    end.flatten
  end

  # A COPY source covers a path if it names it, or names a directory above it.
  def copied?(relative_path, sources)
    sources.any? do |source|
      pattern = source.chomp("/").sub(%r{/\*$}, "")
      relative_path == pattern || relative_path.start_with?("#{pattern}/")
    end
  end

  it "has at least one gemspec to check" do
    expect(GEMSPECS).not_to be_empty
  end

  it "copies everything the gemspecs require before running bundle install" do
    sources = paths_copied_before_bundle_install
    missing = GEMSPECS.flat_map do |gemspec|
      File.read(gemspec).scan(/require_relative\s+["']([^"']+)["']/).flatten.filter_map do |target|
        resolved = Pathname(File.expand_path(target, File.dirname(gemspec)))
        # Only paths outside the plugin matter; plugins/ is copied wholesale.
        next if resolved.to_s.start_with?(File.dirname(gemspec))

        candidates = [ resolved, Pathname("#{resolved}.rb") ]
        relative = candidates.find(&:exist?)&.relative_path_from(Rails.root)&.to_s
        next "#{Pathname(gemspec).basename}: #{target} (does not exist)" if relative.nil?

        "#{Pathname(gemspec).basename} needs #{relative}" unless copied?(relative, sources)
      end
    end

    expect(missing.uniq).to be_empty, <<~MSG
      These plugin gemspecs require files the Docker build has not copied when
      `bundle install` runs, so the image build will fail even though the local
      suite passes. Add a COPY for them above `RUN bundle install`:
        #{missing.uniq.join("\n  ")}
    MSG
  end
end
