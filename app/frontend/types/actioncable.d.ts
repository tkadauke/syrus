declare module "@rails/actioncable" {
  export type Subscription = {
    perform(action: string, data?: Record<string, unknown>): void
    unsubscribe(): void
  }

  export type Consumer = {
    subscriptions: {
      create(params: Record<string, string | number>, mixin: {
        connected?(): void
        disconnected?(event: { willAttemptReconnect: boolean }): void
        received(data: unknown): void
      }): Subscription
    }
  }

  export function createConsumer(url?: string): Consumer
}
