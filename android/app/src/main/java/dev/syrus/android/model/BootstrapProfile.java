package dev.syrus.android.model;

public final class BootstrapProfile {
    private final String email;
    private final String tokenSuffix;

    public BootstrapProfile(String email, String tokenSuffix) {
        this.email = email;
        this.tokenSuffix = tokenSuffix;
    }

    public String getEmail() {
        return email;
    }

    public String getTokenSuffix() {
        return tokenSuffix;
    }
}
