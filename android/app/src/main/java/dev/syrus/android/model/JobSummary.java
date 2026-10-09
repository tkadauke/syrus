package dev.syrus.android.model;

public final class JobSummary {
    private final long id;
    private final String title;
    private final String state;
    private final String summaryState;
    private final String currentStep;
    private final String repositorySlug;

    public JobSummary(
        long id,
        String title,
        String state,
        String summaryState,
        String currentStep,
        String repositorySlug
    ) {
        this.id = id;
        this.title = title;
        this.state = state;
        this.summaryState = summaryState;
        this.currentStep = currentStep;
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

    public String getSummaryState() {
        return summaryState;
    }

    public String getCurrentStep() {
        return currentStep;
    }

    public String getRepositorySlug() {
        return repositorySlug;
    }
}
