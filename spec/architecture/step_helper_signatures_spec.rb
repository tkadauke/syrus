require "rails_helper"

# A Steps subclass that redefines a Steps::Base helper with a different
# signature silently changes the contract for every inherited caller.
#
# Steps::PrOpen and Steps::Push both defined `authenticated_git(git,
# operation_type)` over Base's `authenticated_git(operation_type)` so they
# could pass their own git runner. Base's checkpoint restore then called it
# with one argument and died with `ArgumentError: wrong number of arguments
# (given 1, expected 2)` -- in exactly the two steps that publish a branch,
# and therefore the two that most need to restore a checkpoint. It failed
# silently for hours behind an opportunistic rescue.
#
# Overriding a base method is fine. Changing its arity while keeping its name
# is not: the base class still calls the name it defined.
RSpec.describe "Steps helper signatures" do
  it "keeps subclass overrides compatible with the signature Steps::Base defines" do
    # `descendants` only sees what has been autoloaded, which in a spec run is
    # nothing -- the first version of this guard passed against a deliberately
    # reintroduced override for exactly that reason. Load every step class
    # from disk instead.
    subclasses = Dir[Rails.root.join("app/services/steps/*.rb")].filter_map do |file|
      "Steps::#{File.basename(file, '.rb').camelize}".safe_constantize
    end.select { |klass| klass.is_a?(Class) && klass < Steps::Base }
    expect(subclasses.size).to be > 20

    base_methods = Steps::Base.private_instance_methods(false) + Steps::Base.instance_methods(false)

    mismatches = subclasses.flat_map do |subclass|
      own = subclass.private_instance_methods(false) + subclass.instance_methods(false)
      (own & base_methods).filter_map do |name|
        base_params = Steps::Base.instance_method(name).parameters
        sub_params = subclass.instance_method(name).parameters
        positional = ->(params) { params.count { |kind, _| %i[req opt rest].include?(kind) } }
        next if positional.call(base_params) == positional.call(sub_params)

        "#{subclass}##{name} takes #{positional.call(sub_params)} positional arg(s) " \
          "where Steps::Base##{name} takes #{positional.call(base_params)}"
      end
    end

    expect(mismatches).to eq([]),
      "these overrides change the arity of a Steps::Base helper, so any inherited caller of " \
      "that helper raises ArgumentError:\n  #{mismatches.join("\n  ")}"
  end
end
