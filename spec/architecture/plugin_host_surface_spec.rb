require "rails_helper"

RSpec.describe "Built-in plugin host surface", :ci_only do
  def public_member_exists?(constant, kind, name)
    if kind == "class"
      return true if constant.respond_to?(name)
      return constant.const_get(:ClassMethods, false).method_defined?(name) if constant.const_defined?(:ClassMethods, false)

      return false
    end

    return true if constant.method_defined?(name)
    return constant.new.respond_to?(name) if constant.is_a?(Class)

    false
  end

  it "contains every core constant referenced by a built-in plugin and stays minimal" do
    findings = Admin::PluginHostSurfaceAudit.new.findings

    expect(findings).to eq([]), findings.join("\n")
  end

  it "documents every public entry with a release version" do
    entries = Syrus::PluginHostSurface.new.public_entries

    expect(entries).to all(have_attributes(contract: be_present, since: satisfy { |version| Gem::Version.correct?(version) }))
  end

  it "keeps every public constant and supported member resolvable" do
    surface = Syrus::PluginHostSurface.new
    failures = surface.public_entries.flat_map do |entry|
      constant = entry.name.safe_constantize
      next [ "#{entry.name} does not resolve" ] unless constant

      entry.members.flat_map do |kind, names|
        names.filter_map do |name|
          "#{entry.name} is missing #{kind} member #{name}" unless public_member_exists?(constant, kind, name)
        end
      end
    end

    expect(failures).to eq([]), failures.join("\n")
  end
end
