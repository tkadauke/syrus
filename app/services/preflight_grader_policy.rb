# Explicit admission and isolation policy for the main-branch-repair preflight
# fan-out.
#
# The preflight runs the whole CI grader plan (100+ graders on a large
# repository). Releasing all of them at once dogpiled shared worker and
# database resources, and a single lock timeout or worker death then looked
# like a source failure. This policy owns the three knobs that prevent that:
#
# * wave size       -- how many preflight graders may be released at once; the
#                      fanout chains each wave behind the previous one.
# * retry budget    -- how many times one grader that settled as
#                      `infrastructure_failed` is re-run on a fresh Step/Run
#                      (and so a fresh eligible execution context).
# * database space  -- a per-Step test database namespace, so concurrent
#                      database-using graders never share mutable state, plus
#                      deterministic cleanup of what that namespace created.
module PreflightGraderPolicy
  DEFAULT_WAVE_SIZE = 6
  MAX_WAVE_SIZE = 16
  INFRASTRUCTURE_RETRY_BUDGET = 2
  WAVE_SIZE_ENV = "SYRUS_PREFLIGHT_GRADER_WAVE_SIZE".freeze
  NAMESPACE_PREFIX = "pf".freeze
  # Directories (relative to the grader workspace) config/database.yml places
  # per-TEST_ENV_NUMBER SQLite files in.
  DATABASE_DIRECTORY = "storage".freeze
  DATABASE_FILE_STEMS = %w[test test_search].freeze

  class << self
    def wave_size(env: ENV)
      configured = Integer(env[WAVE_SIZE_ENV].to_s, exception: false)
      return DEFAULT_WAVE_SIZE unless configured&.positive?

      [ configured, MAX_WAVE_SIZE ].min
    end

    def waves(items, size: wave_size)
      items.each_slice([ size.to_i, 1 ].max).to_a
    end

    def retry_budget = INFRASTRUCTURE_RETRY_BUDGET

    def database_namespace(step)
      "#{NAMESPACE_PREFIX}#{step.id}"
    end

    # Environment that points every database-using grader at its own test
    # database. SEARCH_DATABASE_PATH is set explicitly because an inherited
    # value would otherwise win over the TEST_ENV_NUMBER-derived default.
    def database_env(namespace)
      {
        "TEST_ENV_NUMBER" => namespace,
        "SEARCH_DATABASE_PATH" => "#{DATABASE_DIRECTORY}/test_search#{namespace}.sqlite3"
      }
    end

    def database_files(root, namespace)
      directory = Pathname.new(root).join(DATABASE_DIRECTORY)
      DATABASE_FILE_STEMS.flat_map do |stem|
        Dir.glob(directory.join("#{stem}#{namespace}.sqlite3*").to_s)
      end
    end

    # Removes only files carrying this exact namespace. The namespace is unique
    # per Step, so this can never touch another grader's database.
    def cleanup_database!(root, namespace)
      return [] if root.blank? || namespace.blank?

      database_files(root, namespace).each { |path| FileUtils.rm_f(path) }
    end
  end
end
