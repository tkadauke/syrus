package dev.syrus.android.model;

import java.util.Collections;
import java.util.List;

public final class SyrusHomeState {
    private final BootstrapProfile profile;
    private final List<JobSummary> jobs;

    public SyrusHomeState(BootstrapProfile profile, List<JobSummary> jobs) {
        this.profile = profile;
        this.jobs = Collections.unmodifiableList(jobs);
    }

    public BootstrapProfile getProfile() {
        return profile;
    }

    public List<JobSummary> getJobs() {
        return jobs;
    }
}
