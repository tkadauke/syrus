module ApplicationHelper
  GITHUB_REPO = "tkadauke/syrus".freeze

  SYRUS_QUOTES = [
    "A good mind possesses a kingdom.",
    "Anyone can hold the helm when the sea is calm.",
    "Many receive advice, few profit by it.",
    "It is a bad plan that admits of no modification.",
    "Do not turn back when you are just at the goal.",
    "A wise man will be master of his mind, a fool will be its slave.",
    "Treat your friend as if he might become an enemy.",
    "An angry man opens his mouth and shuts his eyes.",
    "Never promise more than you can perform.",
    "He who spares the bad injures the good.",
    "Powerful indeed is the empire of habit.",
    "It matters not what you are thought to be, but what you are.",
    "A small debt produces a debtor; a large one, an enemy.",
    "The bow too tensely strung is easily broken.",
    "He who is bent on doing evil can never want occasion.",
    "Necessity knows no law except to conquer.",
    "A good reputation is more valuable than money.",
    "While we stop to think, we often miss our opportunity.",
    "Speech is the mirror of the soul.",
    "The eyes are not responsible when the mind does the seeing."
  ].freeze

  SYRUS_WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Publilius_Syrus".freeze

  def random_syrus_quote
    SYRUS_QUOTES.sample
  end

  # Constants on a helper module aren't lifted into the view's
  # constant lookup scope (only methods are mixed in). Expose the URL
  # via a method so the layout can `link_to syrus_wikipedia_url, …`.
  def syrus_wikipedia_url
    SYRUS_WIKIPEDIA_URL
  end

  # The git SHA the running image was built from. bin/deploy passes
  # --build-arg GIT_SHA=$(git rev-parse --short HEAD) at build time;
  # the Dockerfile turns that into a runtime ENV. In local dev (no
  # baked SHA) we just say "dev".
  def app_revision
    ENV["GIT_SHA"].presence || "dev"
  end

  # GitHub URL for the running revision, or nil for local dev.
  def app_revision_url
    return nil if app_revision == "dev"
    "https://github.com/#{GITHUB_REPO}/commit/#{app_revision}"
  end

  def relative_timestamp(time, fallback: "—")
    return fallback if time.nil?

    absolute = time.strftime("%b %-d, %Y at %-I:%M %p")
    relative = time > Time.current ? "in #{time_ago_in_words(time)}" : "#{time_ago_in_words(time)} ago"
    content_tag(:time, relative, datetime: time.iso8601, title: absolute, data: { controller: "relative-time" })
  end

  # "3 minutes" — used in place of the noisy "X ago → Y ago" pattern
  # for completed work (workflow / step / run that has both a
  # started_at and a finished_at). The hover-title carries the
  # absolute start/end window so the operator can still see exact
  # times when they need them.
  def duration_caption(started_at, finished_at)
    return nil if started_at.nil? || finished_at.nil?
    span = (finished_at - started_at).to_i
    label =
      if span < 60
        "#{span} #{'second'.pluralize(span)}"
      else
        # ActiveSupport's distance_of_time_in_words returns "less
        # than a minute", "about 3 hours", "1 day", etc. — same
        # English-language scale time_ago_in_words uses, so the
        # caption sits naturally next to relative_timestamp output.
        distance_of_time_in_words(started_at, finished_at)
      end
    title = "#{started_at.strftime('%-I:%M:%S %p')} → #{finished_at.strftime('%-I:%M:%S %p')}"
    content_tag(:span, label, title: title)
  end

  # Generic Tailwind-styled "small enum chip" used by every domain that
  # surfaces a state, kind, or status in a list. Per-domain helpers
  # (state_pill, trigger_pill, scheduled_task_state_pill, …) own the
  # mapping from value → tailwind classes; this is the shared shell.
  PILL_BASE_CLASSES = "inline-block px-2 py-0.5 rounded text-xs font-medium".freeze
  PILL_FALLBACK_CLASSES = "bg-gray-100 text-gray-700".freeze

  def colored_pill(label, classes: PILL_FALLBACK_CLASSES, extra: nil)
    tag.span(label, class: "#{PILL_BASE_CLASSES} #{classes} #{extra}".strip)
  end

  # Background + hover + text classes shared between a SplitButton's
  # primary action and its chevron toggle. Add a new theme by
  # appending here; the partial reads via split_button_theme.
  SPLIT_BUTTON_THEMES = {
    "blue"    => "bg-blue-600 hover:bg-blue-500 text-white",
    "red"     => "bg-red-600 hover:bg-red-500 text-white",
    "amber"   => "bg-amber-600 hover:bg-amber-500 text-white",
    "emerald" => "bg-emerald-600 hover:bg-emerald-500 text-white",
    "gray"    => "bg-gray-200 hover:bg-gray-300 text-gray-800"
  }.freeze

  def split_button_theme(name)
    SPLIT_BUTTON_THEMES[name.to_s] || SPLIT_BUTTON_THEMES["blue"]
  end

  # Render a split button — primary action with a chevron that
  # opens a dropdown of related options. Wraps the partial so
  # callers don't need to remember the path.
  #
  #   <%= split_button(
  #         primary: { label: "Retry", path: run_again_job_path(@job) },
  #         options: [
  #           { label: "Retry from failed step", path: retry_step_job_path(@job, workflow_id: wf.id) },
  #           { label: "Start over",             path: restart_job_path(@job), confirm: "Sure?" }
  #         ],
  #         theme: "blue",
  #         disabled: false
  #       ) %>
  def split_button(primary:, options:, theme: "blue", disabled: false)
    render "shared/split_button",
           primary: primary, options: options,
           theme: theme, disabled: disabled
  end
end
