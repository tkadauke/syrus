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
    "The eyes are not responsible when the mind does the seeing.",
  ].freeze

  SYRUS_WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/Publilius_Syrus".freeze

  def random_syrus_quote
    SYRUS_QUOTES.sample
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
end
