type BadgeNavigator = Navigator & { setAppBadge?: (n?: number) => Promise<void>; clearAppBadge?: () => Promise<void> }

/** Home Screen badge (iOS 16.4+, installed apps with notification permission). Silently unsupported elsewhere. */
export function setBadge(count: number): void {
  const nav = navigator as BadgeNavigator
  try {
    if (count > 0) void nav.setAppBadge?.(count).catch(() => undefined)
    else void nav.clearAppBadge?.().catch(() => undefined)
  } catch {
    // Not supported.
  }
}
