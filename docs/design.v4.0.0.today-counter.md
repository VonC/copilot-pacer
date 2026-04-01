# Design: Fix today bracket for individual licenses

Related issue: [issue.v4.0.0.today-counter.md](issue.v4.0.0.today-counter.md)

---

## Goals

1. Make the today bracket fill correctly for individual Copilot licenses.
2. Make the today bracket represent **intra-day consumption** (requests used since the first fetch of the current UTC day), not cumulative monthly position.
3. Keep `api.ts` changes minimal and `config.ts` unchanged.

---

## Gaps to address

| # | Gap | File | What to change |
| ---- | ---- | ---- | ---- |
| **1** | `quota_snapshots` parsed via direct property key | `api.ts` → `fetchCopilotInternal` | Iterate `Object.values()` and match by `quota_id` field |
| **2** | Uses `quota_remaining` (clamped at 0) instead of `remaining` (can go negative) | `api.ts` → `fetchCopilotInternal` | Read `remaining` instead of `quota_remaining` |
| **4** | Lens computed from cumulative monthly position (Zone 1/2/3), not intra-day usage | `pacing.ts`, `statusBar.ts`, `types.ts` | Daily baseline snapshot in `globalState`; pass `todayUsed` to `calculatePacing` |

Gap #2 is a secondary correctness fix bundled with #1 since both touch the same three lines.  
Gap #4 was discovered after Gaps 1–3 were fixed: even with correct API data, the lens stayed empty for users ahead of their cumulative monthly pace.

---

## Design

### Affected function

`fetchCopilotInternal` in [api.ts](../src/api.ts)

### Current flow

```txt
data.quota_snapshots?.premium_interactions  →  premium object (or undefined)
premium.quota_remaining                     →  remaining count
premium.entitlement                         →  total quota
data.quota_reset_date_utc                   →  period end
```

When the API response keys `quota_snapshots` by something other than `"premium_interactions"` (e.g., individual licenses), the direct property access returns `undefined`, the function throws, and the caller falls back to the billing API with wrong period boundaries.

### New flow

```txt
Object.values(data.quota_snapshots)         →  array of all quota snapshot objects
array.find(q => q.quota_id === "premium_interactions")  →  premium object (or undefined)
premium.remaining                           →  remaining count (real-time, can be negative)
premium.entitlement                         →  total quota
data.quota_reset_date_utc                   →  period end
```

The lookup is now key-agnostic and matches on the `quota_id` field inside each snapshot  --  the same strategy used by vscode-copilot-insights.

### What stays the same (Gaps 1–3)

- **`CopilotUsage` interface** — no new fields needed.
- **`fetchCopilotBilling`** — untouched; still serves as a fallback for users without access to the internal API.
- **`config.ts`** — no changes.

### Why `remaining` instead of `quota_remaining`

The `copilot_internal/user` API returns two distinct remaining fields per quota snapshot:

| Field | Behavior |
| ---- | ---- |
| `quota_remaining` | Clamped — never goes below 0 |
| `remaining` | Real-time — goes negative when over quota |

Using `remaining` means `usedRequests = entitlement - remaining` correctly exceeds `monthlyLimit` when the user is in overage territory, which lets `calculatePacing` show the overage cost in the today lens.

---

## Design — Gap #4: intra-day lens via daily baseline snapshot

### Problem

The old pacing model divided the month into three cumulative zones:

- **Zone 1** (`usedRequests < startOfTodayQuota`): lens = 0 (ahead of pace)
- **Zone 2** (`startOfTodayQuota ≤ usedRequests ≤ endOfTodayQuota`): lens fills proportionally
- **Zone 3** (`usedRequests > endOfTodayQuota`): lens full, future zone fills

A user who is even slightly ahead of the monthly pace is permanently in Zone 1 — the lens shows nothing, regardless of how many requests they send today. This is misleading.

### New semantics

The lens shows **how much of today's adaptive allowance has been consumed since UTC midnight** (`todayUsed`), expressed as a fraction of the adaptive daily budget.

```txt
lensRatio = todayUsed / adaptiveDailyBudget   (clamped to [0, 1])
```

`adaptiveDailyBudget` is computed **once per UTC day** and stored in `globalState`:

```txt
adaptiveDailyBudget = max(1, remainingRequests / remainingDays)

where:
  remainingRequests = monthlyLimit − baseline   (requests left for the rest of the period)
  remainingDays     = days from today (inclusive) to period end
```

This automatically accounts for borrowed or saved requests from previous days:

- If requests were over-consumed yesterday, `remainingRequests` is smaller → smaller budget today.
- If requests were conserved, `remainingRequests` is larger → larger budget today.

| Denominator | Formula | Status |
| ---- | ---- | ---- |
| **Adaptive quota** | `remainingRequests / remainingDays` | ✅ implemented |
| Static budget | `monthlyLimit / totalDays` | retained internally for past-zone comparison only |

The past zone still uses the static budget as its reference line (`accumulatedBeforeToday / dayStartQuota`), which measures how well accumulated usage through yesterday tracks the expected linear pace.

- 0 % at the start of the UTC day
- 100 % when `adaptiveDailyBudget` requests have been used today
- Lens stays full and the future zone fills when `todayUsed > adaptiveDailyBudget`

### Daily baseline snapshot

Since the GitHub API only exposes cumulative monthly usage, today's consumption is derived by a stored baseline:

```txt
todayUsed = currentUsedRequests − baseline
```

The baseline is stored in `context.globalState` under the key `copilot-pacer.dailyBaseline` as:

```json
{ "date": "YYYY-MM-DD", "baseline": 1106, "lastSeen": 1130, "periodStartKey": "YYYY-MM-DD" }
```

| Field | Meaning | Updated when |
| ---- | ---- | ---- |
| `date` | Current UTC date (`YYYY-MM-DD`) | On day rollover |
| `baseline` | Cumulative count at the start of the UTC day | On day rollover — set from the previous day's `lastSeen` |
| `lastSeen` | Most recent cumulative count observed this session | On every refresh |
| `periodStartKey` | Current billing-period start date (`YYYY-MM-DD`) | On every refresh; used to detect monthly counter resets |

On a normal day rollover (`stored.date ≠ todayKey`), `baseline` is set to the previous day's `lastSeen`. This ensures that requests made **after VS Code was last closed** the previous day are still attributed to that day, and the new day starts from an accurate baseline.

On the first day of a new billing period (`periodStartKey === todayKey`), the monthly counter has reset, so `baseline` is forced to `0`.

**First-ever run:** on a non-period-start day, no `lastSeen` exists yet, so `baseline = currentUsed` and `todayUsed = 0` for that initial session. On the first day of a new billing period, `baseline = 0` so early-month usage is counted immediately.

> **Limitation:** Requests sent today *before* the extension was first activated are not reflected in `todayUsed` for that day. The counter self-corrects at the next UTC midnight rollover.

### Adaptive quota snapshot

The adaptive daily budget depends on `baseline` (set at day rollover) and `periodEnd` (from the API). It is stored under the key `copilot-pacer.adaptiveQuota` as:

```json
{ "date": "YYYY-MM-DD", "quota": 72, "periodStartKey": "YYYY-MM-DD", "baseline": 1106 }
```

| Field | Meaning | Updated when |
| ---- | ---- | ---- |
| `date` | UTC date this quota applies to | On day rollover |
| `quota` | Adaptive daily budget (`remainingRequests / remainingDays`) | When the cache matches the current day state |
| `periodStartKey` | Billing-period start date for which this quota was computed | Used to reject stale same-day cache entries after a monthly reset |
| `baseline` | Opening baseline used to compute this quota | Used to reject stale same-day cache entries after the baseline changes |

The quota is computed with `daysUntilPeriodEnd(periodEnd)`, which counts calendar UTC days from today (inclusive) to `periodEnd` (exclusive), clamped to a minimum of 1:

```typescript
function daysUntilPeriodEnd(periodEnd: Date): number {
  const now = new Date();
  const todayMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const endMs = Date.UTC(periodEnd.getUTCFullYear(), periodEnd.getUTCMonth(), periodEnd.getUTCDate());
  return Math.max(1, Math.ceil((endMs - todayMs) / (24 * 60 * 60 * 1000)));
}
```

The quota is **not** recalculated on every refresh. It is reused only when the UTC date, billing-period start, and opening baseline all still match. If any of those differ, the cache is dropped and the quota is recomputed immediately. This fixes the April 1 case where a stale same-day quota from the old month could survive into the new billing period.

**First-ever run — full initialization trace:**

`activate()` calls `updatePacing()` immediately (no defer). Assuming `currentUsed = 1108`, `monthlyLimit = 1500`, `periodEnd = 2026-04-01`, today = `2026-03-29` (3 days remaining):

```txt
1. getTodayUsed(usage)
   stored (dailyBaseline) = undefined
   → baseline = 1108  (no lastSeen, use currentUsed)
  → writes { date: "2026-03-29", baseline: 1108, lastSeen: 1108, periodStartKey: "2026-03-01" }
   → returns max(0, 1108 − 1108) = 0

2. getAdaptiveDailyBudget(usage)
   storedQuota (adaptiveQuota) = undefined  → recompute
  storedBaseline = { date: "2026-03-29", baseline: 1108, lastSeen: 1108, periodStartKey: "2026-03-01" }  ← just written above
   remainingRequests = max(0, 1500 − 1108) = 392
   remainingDays     = 3
   quota             = max(1, 392 / 3) ≈ 131
  → writes { date: "2026-03-29", quota: 131, periodStartKey: "2026-03-01", baseline: 1108 }
   → returns 131

Result: lens shows 0 / 131  (empty — no requests sent yet this session)
        both settings written; Settings Sync propagates them to other machines
```

The adaptive quota on first-ever run is computed from the **current position** (`monthlyLimit − currentUsed`), so it is immediately meaningful. Both settings are guaranteed to be written on the very first successful API call — including during a debug session (F5 → Extension Development Host), because the EDH uses the same user data directory and `globalState` storage as a regular VS Code install.

### Cross-machine synchronisation

`context.globalState` is machine-local by default. To share the baseline across multiple VS Code instances on different machines using the same GitHub account, the extension registers the key with VS Code's **Settings Sync** infrastructure:

```typescript
globalState.setKeysForSync(["copilot-pacer.dailyBaseline", "copilot-pacer.adaptiveQuota"]);
```

When Settings Sync is enabled, this entry is propagated within seconds to all other machines signed in to the same account — the same channel that syncs settings, keybindings, and snippets.

The formula remains correct across machines because the GitHub API's `currentUsed` is the cumulative total for the **entire account** (all machines combined). The shared `baseline` therefore yields the same `todayUsed = currentUsed − baseline` on every machine, converging on the true intra-day consumption regardless of which machine triggered the refresh.

**Concurrent midnight rollover:** if two machines both refresh within the same timer window straddling UTC midnight, they each write `{ date: today, baseline: stored.lastSeen }`. Since `lastSeen` was already synced, they write identical data — no conflict.

### Affected files

| File | Change |
| ---- | ---- |
| `types.ts` | Add `todayUsedRequests: number` and `dailyBudget: number` to `PacingResult` |
| `pacing.ts` | New signature `calculatePacing(usage, todayUsed, adaptiveDailyBudget)`; remove Zone 1/2/3; static budget kept for past-zone reference only; new `lensRatio`/`futureRatio` use `adaptiveDailyBudget` |
| `statusBar.ts` | Store `globalState`; add `getTodayUsed()`, `daysUntilPeriodEnd()`, `getAdaptiveDailyBudget()` helpers; sync both keys; pass `todayUsed` + `adaptiveDailyBudget` to `calculatePacing`; update tooltip |
| `extension.ts` | Add output channel (diagnostic logging — already applied) |

### Tooltip changes

Before:

```txt
Requests: 1106 / 1500
✅ On track. Remaining today: ~297 requests.
```

After:

```txt
Requests: 1106 / 1500
Today: 12 / 48
✅ Remaining today: ~36 requests.
```

---

## Scope boundaries

The following are explicitly **out of scope** for this change:

- **Billing API period fix** — The calendar-month assumption in `fetchCopilotBilling` is inaccurate, but fixing it is unnecessary once the internal API works. Can be revisited separately.
- **Token counter / chat event tracking** — Already working; not affected by this change.
- **Full snapshot history** — vscode-copilot-insights records up to 10 snapshots for trend analysis. Pacer only stores one baseline per day — sufficient for the lens display.

---

## Verification

After applying the fix:

1. **Today bracket fills immediately** — On first refresh of the day the lens shows 0; subsequent refreshes show intra-day consumption relative to `dailyBudget`.
2. **Ahead-of-pace users** — Lens now fills based on actual today usage, not cumulative position. Zone 1 is eliminated.
3. **Over daily budget** — When `todayUsed > dailyBudget`, lens is full and the future zone fills. Tooltip shows "Over daily budget!"
4. **Monthly overage** — When `usedRequests > monthlyLimit`, the lens shows the dollar cost (`┃$x.xx┃`) and the status bar turns red. Unchanged.
5. **No internal API access** — Falls back to billing API as before. `todayUsed` still computed from globalState baseline. No regression.
