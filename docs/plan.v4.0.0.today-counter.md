# Plan: Fix today bracket for individual licenses

Related design: [design.v4.0.0.today-counter.md](design.v4.0.0.today-counter.md)
Related issue: [issue.v4.0.0.today-counter.md](issue.v4.0.0.today-counter.md)

---

## Scope

Four files modified in total across two phases.

**Phase 1 — API fix (Gaps 1–3):** `src/api.ts` only.  
**Phase 2 — Intra-day lens (Gap 4):** `src/types.ts`, `src/pacing.ts`, `src/statusBar.ts`, `src/extension.ts`.

---

## Phase 1 — API fix ✅

### Step 1 — Replace direct property access with value iteration ✅

**File:** `src/api.ts`, `fetchCopilotInternal`

**Before:**
```typescript
const premium = data.quota_snapshots?.premium_interactions;
```

**After:**
```typescript
const quotaArr = data.quota_snapshots
  ? Object.values(data.quota_snapshots) as any[]
  : [];
const premium = quotaArr.find(
  (q: any) => q.quota_id === "premium_interactions"
);
```

**Why:** The internal API keys `quota_snapshots` differently for individual licenses. Key-agnostic `Object.values().find()` matches regardless of the property name.

---

### Step 2 — Read `remaining` instead of `quota_remaining` ✅

**File:** `src/api.ts`, `fetchCopilotInternal`

**Before:**
```typescript
const remaining = premium.quota_remaining as number;
```

**After:**
```typescript
const remaining = premium.remaining as number;
```

**Why:** `quota_remaining` is clamped at 0. `remaining` can go negative, making `usedRequests = entitlement - remaining` accurate during overage.

---

## Phase 2 — Intra-day lens ✅

### Step 3 — Add `todayUsedRequests` and `dailyBudget` to `PacingResult` ✅

**File:** `src/types.ts`

Add two fields to the `PacingResult` interface:
```typescript
todayUsedRequests: number;   // requests used since first fetch of current UTC day
dailyBudget: number;         // adaptive daily quota: remainingRequests / remainingDays
```

---

### Step 4 — Refactor `calculatePacing` to accept `todayUsed` and `adaptiveDailyBudget` ✅

**File:** `src/pacing.ts`

- Change signature to `calculatePacing(usage: CopilotUsage, todayUsed: number, adaptiveDailyBudget: number)`
- Remove Zone 1/2/3 logic; replace with:

```typescript
// Static budget for the past-zone reference line only
const staticDailyBudget = monthlyLimit / totalDays;
const dayStartQuota = pastDays * staticDailyBudget;

// Past: proportion of expected pace consumed through yesterday
const accumulatedBeforeToday = usedRequests - todayUsed;
const pastRatio = dayStartQuota === 0
  ? 1
  : Math.min(1, Math.max(0, accumulatedBeforeToday / dayStartQuota));

// Today: intra-day usage vs adaptive daily budget
const lensRatio = Math.min(1, Math.max(0, todayUsed / adaptiveDailyBudget));

// Future: fills only when today's usage exceeds the adaptive daily budget
const futureQuota = Math.max(0, monthlyLimit - accumulatedBeforeToday - adaptiveDailyBudget);
const futureRatio = futureQuota > 0
  ? Math.min(1, Math.max(0, (todayUsed - adaptiveDailyBudget) / futureQuota))
  : 0;
```

- Change `buffer` to `adaptiveDailyBudget - todayUsed`
- Return `todayUsedRequests: todayUsed` and `dailyBudget: adaptiveDailyBudget` in the result

---

### Step 5 — Add daily baseline snapshot and adaptive quota to `statusBar.ts` ✅

**File:** `src/statusBar.ts`

1. Change `globalState` variable type to include `setKeysForSync`:
```typescript
let globalState: vscode.Memento & { setKeysForSync(keys: readonly string[]): void };
```

2. In `initStatusBar`, store `globalState = context.globalState` and register **both** keys for VS Code Settings Sync:

```typescript
globalState.setKeysForSync(["copilot-pacer.dailyBaseline", "copilot-pacer.adaptiveQuota"]);
```

3. Add helper `getTodayUsed`. The stored entry has shape `{ date, baseline, lastSeen }`. On day rollover the previous day's `lastSeen` becomes the new `baseline`, so requests made after VS Code last closed are attributed to yesterday — and the new day starts from an accurate baseline.

```typescript
function getTodayUsed(currentUsed: number): number {
  const todayKey = new Date().toISOString().slice(0, 10); // 'YYYY-MM-DD' UTC
  const stored = globalState.get<{ date: string; baseline: number; lastSeen: number }>(
    "copilot-pacer.dailyBaseline"
  );
  if (!stored || stored.date !== todayKey) {
    const baseline = stored ? stored.lastSeen : currentUsed;
    globalState.update("copilot-pacer.dailyBaseline", {
      date: todayKey, baseline, lastSeen: currentUsed,
    });
    return Math.max(0, currentUsed - baseline);
  }
  globalState.update("copilot-pacer.dailyBaseline", { ...stored, lastSeen: currentUsed });
  return Math.max(0, currentUsed - stored.baseline);
}
```

4. Add helper `daysUntilPeriodEnd`:
```typescript
function daysUntilPeriodEnd(periodEnd: Date): number {
  const now = new Date();
  const todayMs = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
  const endMs = Date.UTC(periodEnd.getUTCFullYear(), periodEnd.getUTCMonth(), periodEnd.getUTCDate());
  return Math.max(1, Math.ceil((endMs - todayMs) / (24 * 60 * 60 * 1000)));
}
```

5. Add helper `getAdaptiveDailyBudget`. Computed once per UTC day from the day's opening `baseline` and `periodEnd`. Cached in `copilot-pacer.adaptiveQuota` as `{ date, quota }`.

```typescript
function getAdaptiveDailyBudget(usage: CopilotUsage): number {
  const todayKey = new Date().toISOString().slice(0, 10);
  const storedQuota = globalState.get<{ date: string; quota: number }>(
    "copilot-pacer.adaptiveQuota"
  );
  if (storedQuota && storedQuota.date === todayKey) { return storedQuota.quota; }

  const storedBaseline = globalState.get<{ date: string; baseline: number; lastSeen: number }>(
    "copilot-pacer.dailyBaseline"
  );
  const todayStartUsed = storedBaseline?.baseline ?? usage.usedRequests;
  const remainingRequests = Math.max(0, usage.monthlyLimit - todayStartUsed);
  const remainingDays = daysUntilPeriodEnd(usage.periodEnd);
  const quota = Math.max(1, remainingRequests / remainingDays);

  globalState.update("copilot-pacer.adaptiveQuota", { date: todayKey, quota });
  ext.outputChannel.appendLine(
    `[adaptive quota] remaining=${Math.round(remainingRequests)} / ${remainingDays} days → ${Math.round(quota)}/day`
  );
  return quota;
}
```

6. In `updatePacing`, after fetching `usage`, call both helpers and pass results to `calculatePacing`:
```typescript
const todayUsed = getTodayUsed(usage.usedRequests);
const adaptiveDailyBudget = getAdaptiveDailyBudget(usage);
const result = calculatePacing(usage, todayUsed, adaptiveDailyBudget);
```

7. Update tooltips to include `Today: X / Y` line and correct color logic:
   - Red (`errorForeground`): monthly overage (`overageCost > 0`)
   - Orange (`warningForeground`): over daily budget (`buffer < 0`)
   - Normal: within daily budget

---

### Step 6 — Add output channel to `extension.ts` ✅

**File:** `src/extension.ts`

Export `outputChannel: vscode.OutputChannel` so `statusBar.ts` can log diagnostic lines:
```
[internal API] used=1106 / 1500 | period 2026-03-01 → 2026-04-01
[today] used=12 / 48
```

---

## What does NOT change

- `src/api.ts` — `fetchCopilotBilling`, `fetchUsername`, shared helpers — unchanged.
- `src/config.ts` — unchanged.
- `src/extension.ts` — command registrations, timer — unchanged.
- `src/types.ts` — `CopilotUsage`, error classes — unchanged.

---

## Verification checklist

| Scenario | Expected outcome |
| ---- | ---- |
| First VS Code open of the day | `todayUsed = 0` on very first ever run; from the second day onward uses previous `lastSeen` as baseline |
| After N requests in session | Lens fills to `N / dailyBudget` fraction |
| Over daily budget (`todayUsed > dailyBudget`) | Lens full, future zone fills, tooltip shows "Over daily budget!" |
| Over monthly limit | Lens shows `$x.xx`, status bar red |
| Ahead of cumulative pace | Lens still fills based on intra-day usage (Zone 1 eliminated) |
| No internal API access | Falls back to billing API; `todayUsed` still computed from globalState |
