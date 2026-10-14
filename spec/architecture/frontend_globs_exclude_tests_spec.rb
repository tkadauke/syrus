require "rails_helper"

# `import.meta.glob("<dir>/*.tsx")` also matches `<dir>/Thing.test.tsx`, so a
# glob without an exclusion pulls every colocated test file into the module
# graph. The consumers all filter test modules out at runtime -- their path
# regexes use `[^/.]+`, which a name containing `.test` cannot satisfy -- so
# nothing misbehaves and the mistake is invisible in the app.
#
# Rollup still emits a chunk per reachable module, though. A production build
# shipped 35 test chunks (~317 KB) this way, and one of them was dependency
# index 0 in the entry's `__vite__mapDeps`, which puts test code and its
# vitest-flavored imports inside the lazy-route graph of a production page.
#
# `emptyOutDir: false` is why this survived: a local rebuild leaves previous
# chunks in place, so the count never visibly drops and the leftovers look
# like current output.
RSpec.describe "frontend module globs exclude test files" do
  GLOB_SOURCE_GLOBS = [
    "app/frontend/**/*.{ts,tsx}",
    "plugins/*/app/frontend/**/*.{ts,tsx}"
  ].freeze

  # Captures the whole `import.meta.glob(...)` argument list, single-pattern
  # or array, across line breaks, up to the options hash or closing paren.
  GLOB_CALL = /import\.meta\.glob(?:<[^>]*>)?\(\s*(\[.*?\]|"[^"]*")/m

  # Only globs that can match a colocated test file need an exclusion. A glob
  # over `*.json` locales or an explicitly named file cannot.
  SCRIPT_PATTERN = /\*\.(?:tsx?|\{ts,tsx\})"/

  def offending_globs
    Rails.root.glob(GLOB_SOURCE_GLOBS.first).then do |core|
      (core + Rails.root.glob(GLOB_SOURCE_GLOBS.last)).flat_map do |path|
        next [] if path.to_s.include?("/node_modules/")

        source = path.read
        source.scan(GLOB_CALL).flat_map do |(arguments)|
          next [] unless arguments.match?(SCRIPT_PATTERN)
          next [] if arguments.include?(".test.")

          [ "#{path.relative_path_from(Rails.root)}: #{arguments.gsub(/\s+/, ' ').truncate(120)}" ]
        end
      end
    end
  end

  it "negates test files in every glob that can match them" do
    expect(offending_globs).to eq([]), <<~MESSAGE
      These import.meta.glob calls match colocated test files, so Rollup emits a
      chunk for each one and ships test code to production. Add a negative
      pattern alongside the positive one, e.g.

        import.meta.glob([ "../../plugins/*/app/frontend/routes/*.tsx",
                           "!../../plugins/*/app/frontend/routes/*.test.tsx" ])

      Offending globs:
        #{offending_globs.join("\n  ")}
    MESSAGE
  end
end
