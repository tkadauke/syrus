import { EventEmitter } from "node:events"

export const DESKTOP_NOTIFICATION_EVENT = "notification"

export const desktopNotificationEvents = new EventEmitter()
