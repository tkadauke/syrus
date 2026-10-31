module CoworkerGrantHelpers
  def expect_coworker_grants_declared(tool_set)
    catalog = Coworkers::GrantCatalog.all.index_by(&:name)
    missing = Array(tool_set.tool_definitions(tier: nil)).select do |definition|
      safe = definition[:coworker_safe] || definition["coworker_safe"]
      grantless = definition[:coworker_grantless] || definition["coworker_grantless"]
      capability = definition[:capability] || definition["capability"]
      tool_name = definition[:name] || definition["name"]
      safe && !grantless && !catalog[capability.to_s]&.tools&.include?(tool_name.to_s)
    end
    expect(missing).to be_empty, "undeclared coworker tools: #{missing.map { |definition| definition[:name] || definition['name'] }.join(', ')}"
  end
end

RSpec.configure { |config| config.include CoworkerGrantHelpers }
