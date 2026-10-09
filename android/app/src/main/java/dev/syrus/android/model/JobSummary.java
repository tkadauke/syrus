package dev.syrus.android.model;

public final class JobSummary {
    private final long id;
    private final String title;
    private final String state;
    private final String repositorySlug;

    public JobSummary(long id, String title, String state, String repositorySlug) {
        this.id = id;
        this.title = title;
        this.state = state;
        this.repositorySlug = repositorySlug;
    }

    public long getId() {
        return id;
    }

    public String getTitle() {
        return title;
    }

    public String getState() {
        return state;
    }

    public String getRepositorySlug() {
        return repositorySlug;
    }
}
