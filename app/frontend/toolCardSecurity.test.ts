import { describe, expect, it } from "vitest"
import type { ChatToolGroupCall } from "./api/chats"
import { toolCardContext } from "./routes/chat/MessageCards"
import { redactToolCardText, redactToolCardValue, toolCardPayloadSizeLabel } from "./toolCardSecurity"

describe("toolCardSecurity", () => {
  it("redacts sensitive object keys recursively", () => {
    expect(
      redactToolCardValue({
        safe: "visible",
        api_token: "tok_live_123456789",
        accessToken: "access-secret-123456",
        nested: { password: "hunter2-secret", rows: [{ client_secret: "shh-123456", refreshToken: "refresh-secret-123456" }] }
      })
    ).toEqual({
      safe: "visible",
      api_token: "[redacted]",
      accessToken: "[redacted]",
      nested: { password: "[redacted]", rows: [{ client_secret: "[redacted]", refreshToken: "[redacted]" }] }
    })
  })

  it("redacts inline token-like text", () => {
    expect(redactToolCardText("Authorization: Bearer abcdefghijklmnopqrstuvwxyz and password=hunter2-secret and accessToken=access-secret-123456")).toBe(
      "Authorization: Bearer [redacted] and password=[redacted] and accessToken=[redacted]"
    )
  })

  it("redacts environment-style secret assignments with prefixed key names", () => {
    expect(
      redactToolCardText(
        [
          "DATABASE_PASSWORD=hunter2hunter2",
          "MY_API_KEY=abcdef123456789",
          "export GITHUB_TOKEN=abcdef123456",
          "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
          "SECRET_KEY_BASE=0123456789abcdef0123456789abcdef"
        ].join("\n")
      )
    ).toBe(
      [
        "DATABASE_PASSWORD=[redacted]",
        "MY_API_KEY=[redacted]",
        "export GITHUB_TOKEN=[redacted]",
        "AWS_SECRET_ACCESS_KEY=[redacted]",
        "SECRET_KEY_BASE=[redacted]"
      ].join("\n")
    )
  })

  it("redacts entire quoted secret assignment values", () => {
    expect(redactToolCardText('password = "hunter two"')).toBe('password = "[redacted]"')
  })

  it("redacts quoted secret assignment values with escaped quotes", () => {
    expect(redactToolCardText(String.raw`password = "hunter \"two\" tail"`)).toBe('password = "[redacted]"')
  })

  it("redacts camelCase token keys in JSON-ish text", () => {
    expect(redactToolCardText('{"accessToken":"access-secret-123456","safe":"visible"}')).toBe('{"accessToken":"[redacted]","safe":"visible"}')
  })

  it("redacts bare secret-like values from compact detail strings", () => {
    expect(redactToolCardText("plugin-input-secret-123456")).toBe("[redacted]")
    expect(redactToolCardText("MYSECRETTOKENVALUE")).toBe("[redacted]")
  })

  it("preserves non-string and diagnostic metadata under sensitive-looking keys", () => {
    expect(
      redactToolCardValue({
        credential_mode: "app",
        app_credential_active: true,
        app_credential_inactive_reason: "missing_installation",
        jwt_usable: false,
        jwt_error_message: "certificate expired",
        jwt_error_class: "OpenSSL::JWTError",
        private_key_present: true,
        token_count: 2,
        secret: null,
        password: 0,
        jwt: "signed.jwt.value",
        client_secret: "still-secret"
      })
    ).toEqual({
      credential_mode: "app",
      app_credential_active: true,
      app_credential_inactive_reason: "missing_installation",
      jwt_usable: false,
      jwt_error_message: "certificate expired",
      jwt_error_class: "OpenSSL::JWTError",
      private_key_present: true,
      token_count: 2,
      secret: null,
      password: 0,
      jwt: "[redacted]",
      client_secret: "[redacted]"
    })
  })

  it("keeps credential metadata objects while redacting secrets inside them", () => {
    expect(
      redactToolCardValue({
        credential: {
          credential_id: 42,
          credential_name: "production-cluster",
          credential_type: "kubeconfig",
          client_secret: "hidden-value",
          token: "hidden-token"
        }
      })
    ).toEqual({
      credential: {
        credential_id: 42,
        credential_name: "production-cluster",
        credential_type: "kubeconfig",
        client_secret: "[redacted]",
        token: "[redacted]"
      }
    })
  })

  it("keeps secret resource metadata without exposing data values", () => {
    expect(
      redactToolCardValue({
        available: true,
        secret: {
          name: "db-credentials",
          namespace: "default",
          type: "Opaque",
          key_count: 2,
          key_names: ["DATABASE_PASSWORD_VALUE", "username"],
          immutable: true,
          owner_references: ["Deployment/api"],
          data: { DATABASE_PASSWORD_VALUE: "hunter2-secret" }
        }
      })
    ).toEqual({
      available: true,
      secret: {
        name: "db-credentials",
        namespace: "default",
        type: "Opaque",
        key_count: 2,
        key_names: ["DATABASE_PASSWORD_VALUE", "username"],
        immutable: true,
        owner_references: ["Deployment/api"],
        data: "[redacted]"
      }
    })
  })

  it("preserves key-name lists and resource identifiers without weakening assignments", () => {
    expect(
      redactToolCardValue({
        key_names: ["DATABASE_PASSWORD_VALUE", "API_TOKEN_NAME"],
        resource_name: "application-secret-config",
        output: "DATABASE_PASSWORD_VALUE=hunter2-secret"
      })
    ).toEqual({
      key_names: ["DATABASE_PASSWORD_VALUE", "API_TOKEN_NAME"],
      resource_name: "application-secret-config",
      output: "DATABASE_PASSWORD_VALUE=[redacted]"
    })
  })

  it("redacts the complete tool-card context without blanking diagnostic or kubectl metadata", () => {
    const diagnostic = contextFor({
      tool_name: "admin_github_app_installation_diagnostic",
      result_json: {
        jwt_usable: true,
        jwt_error_message: null,
        private_key_present: true,
        credential_mode: "app",
        app_credential_active: true
      }
    })
    const kubectl = contextFor({
      tool_name: "k8s_cluster_kubectl",
      raw_payload: { credential: 7 },
      result_json: { credential: { credential_id: 7, credential_name: "cluster-admin", credential_type: "kubeconfig", password: "raw-password" } }
    })

    expect(diagnostic.parsedResult).toEqual({
      jwt_usable: true,
      jwt_error_message: null,
      private_key_present: true,
      credential_mode: "app",
      app_credential_active: true
    })
    expect(kubectl.input.credential).toBe(7)
    expect(kubectl.parsedResult).toEqual({
      credential: { credential_id: 7, credential_name: "cluster-admin", credential_type: "kubeconfig", password: "[redacted]" }
    })
  })

  it("redacts credentials embedded in command output", () => {
    const text = [
      "DATABASE_URL=postgres://database_user:database-password@example.test/app",
      "curl -u api-user:api-password https://example.test",
      "-----BEGIN RSA PRIVATE KEY-----",
      "private-key-material",
      "-----END RSA PRIVATE KEY-----"
    ].join("\n")

    expect(redactToolCardText(text)).toBe(
      ["DATABASE_URL=postgres://database_user:[redacted]@example.test/app", "curl -u api-user:[redacted] https://example.test", "[redacted]"].join("\n")
    )
  })

  it("reports payload size in bytes for small payloads", () => {
    expect(toolCardPayloadSizeLabel("abc")).toBe("3 B")
  })
})

function contextFor(overrides: Partial<ChatToolGroupCall>) {
  return toolCardContext({
    message_id: 1,
    tool_name: "tool",
    raw_name: "",
    detail: "",
    display_label: "Tool",
    progress_label: "Running",
    raw_payload: {},
    result_body: "",
    result_error: false,
    result_kind: "text",
    result_summary: "",
    ...overrides
  })
}
