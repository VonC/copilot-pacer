# Issue: Today bracket remains empty

## Description of the issue for copilot-pacer plugin

I do see the token counter being correctly updated every time I send a query in GitHub Copilot chat, and the month bracket is correctly updated as well, but the today bracket remains empty.

Why? I do use an individual licence, using <https://api.individual.githubcopilot.com/>.

Can you check if there is any issue with the API endpoint for individual licenses that could be causing the today bracket to remain empty?

Is there anything done in the other plugin vscode-copilot-insights that is not done in copilot-pacer that could be causing this issue?

I need to understand the minimal gap which explains why the today bracket is not being updated, while the month bracket and token counter are correctly updated.

---

## Analysis

### How the today bracket works (old behavior)

The copilot-pacer status bar displays a progress bar with three zones:

```txt
[past ▰▱][today ┃▮▯┃][future ▰▱]
```

The **today bracket** (the `┃…┃` lens) was computed in `calculatePacing()` by dividing the monthly quota into equal daily slices and checking where **cumulative** monthly usage falls relative to **today's** window:

- `dailyBudget = monthlyLimit / totalDays`
- `startOfTodayQuota = pastDays × dailyBudget`
- `endOfTodayQuota = currentDay × dailyBudget`

| Condition | Zone | lensRatio |
| ---- | ---- | ---- |
| `usedRequests < startOfTodayQuota` | 1  --  ahead of schedule | **0** (today bracket empty) |
| `startOfTodayQuota ≤ usedRequests ≤ endOfTodayQuota` | 2  --  on track | proportional fill |
| `usedRequests > endOfTodayQuota` | 3  --  over budget | **1** (today bracket full) |

The today bracket shows **all empty blocks** (`┃▯▯▯▯▯┃`) whenever the user is in Zone 1. **Any user who has been even slightly conservative through the month sits permanently in Zone 1 — the lens shows nothing no matter how many requests they send today.**

#### Zone 1 worked example

```log
Plan: 1500 requests / 31 days  →  dailyBudget ≈ 48/day
Today: day 28  →  startOfTodayQuota = 27 × 48 ≈ 1306

User has been conservative: usedRequests = 1106
  1106 < 1306  →  Zone 1  →  lensRatio = 0  →  ┃▯▯▯▯▯┃ (empty)
```

The user would need to fire ~200 more requests before the lens even begins to fill — that is 4× their daily budget in a single session. The lens gives no useful feedback for the entire day.

### Root cause: `quota_snapshots` parsing difference

#### copilot-pacer  --  direct property access

In [api.ts](../src/api.ts#L48-L55):

```typescript
const premium = data.quota_snapshots?.premium_interactions;
if (!premium || premium.unlimited) {
  throw new Error("No premium_interactions quota in internal API response");
}
const entitlement = premium.entitlement as number;
const remaining   = premium.quota_remaining as number;
```

That accesses `quota_snapshots.premium_interactions` as a **direct property key**. If the API response uses a different key (e.g., a numeric index, a UUID, or a different string), `premium` is `undefined` → the internal API fetch **throws** → falls back to the billing API.

#### vscode-copilot-insights  --  robust value iteration

In [extension.ts](../../vscode-copilot-insights/src/extension.ts#L220-L221):

```typescript
const quotaArr = data.quota_snapshots
  ? Object.values(data.quota_snapshots) : [];
const premiumQ = quotaArr.find(
  (q) => q.quota_id === "premium_interactions"
);
```

That iterates over **all values** and matches by the `quota_id` field, which works regardless of the object key name. That is why vscode-copilot-insights correctly reads usage for individual licenses while copilot-pacer may not.

### What happens after the internal API fails  --  the billing API fallback

When `fetchCopilotInternal` throws, copilot-pacer falls back to `fetchCopilotBilling` ([api.ts](../src/api.ts#L73-L93)):

```typescript
// Billing API does not expose period dates  --  assume calendar month
const periodStart = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
const periodEnd   = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1));
```

Two problems arise:

1. **Wrong period boundaries**: Individual Copilot plans reset on `quota_reset_date_utc`, which rarely falls on the 1st of the month. By assuming calendar-month boundaries, `totalDays` and `currentDay` can be significantly off, inflating `startOfTodayQuota` beyond the actual `usedRequests` → perpetual Zone 1 → empty today bracket.

2. **Billing API data lag**: The official billing endpoint (`/users/{username}/settings/billing/usage/summary`) may lag behind real-time usage, further depressing `usedRequests` relative to the computed `startOfTodayQuota`.

#### Worked example

```log
Real billing cycle: March 15 → April 15 (31 days)
Billing API assumes: March 1 → April 1 (31 days)
Today: March 29

With billing API assumptions:
  currentDay       = 29
  dailyBudget      = 300 / 31 ≈ 9.68
  startOfTodayQuota = 28 × 9.68 = 271

Actual usage = 100 (user is 14 days into their real cycle)
  100 < 271 → Zone 1 → lensRatio = 0 → today bracket empty ┃▯▯▯▯▯┃
```

The month bracket (past zone `▰▱`) still shows correct proportional fill (`100 / 271 ≈ 37%`), which matches the user's observation that "the month bracket is correctly updated."

### Secondary gap: `remaining` vs `quota_remaining`

The `copilot_internal/user` API response contains two distinct remaining fields per quota snapshot:

| Field | Used by |
| ---- | ---- |
| `quota_remaining` | copilot-pacer ([api.ts](../src/api.ts#L54)) |
| `remaining` | vscode-copilot-insights (for overage detection, snapshot history, predictions) |

vscode-copilot-insights defines both in its `QuotaSnapshot` interface ([extension.ts](../../vscode-copilot-insights/src/extension.ts#L17-L18)):

```typescript
quota_remaining: number;
remaining: number;
```

`remaining` can go **negative** (indicating overage) while `quota_remaining` appears to be clamped. For individual licenses, these values may diverge, causing copilot-pacer's `usedRequests = entitlement - quota_remaining` to under-report actual usage.

### Additional gap: no local snapshot tracking

vscode-copilot-insights tracks a **local history** of up to 10 snapshots with timestamps ([extension.ts](../../vscode-copilot-insights/src/extension.ts#L533-L555)). That enables:

- "Since last refresh" delta
- "Since yesterday" delta
- Burn rate analysis and weighted predictions

copilot-pacer has **no local state**  --  every refresh is a one-shot API call. It cannot compute how many requests were made _today_ specifically; it can only check where cumulative usage falls within a computed daily budget window.

### What the user actually wants: per-day consumption against an adaptive allowance

The user's goal is:

> **"How much of today's personal allowance have I already consumed during this UTC day?"**

This requires two things:

1. **Intra-day count** (`todayUsed`): requests made since UTC midnight — not the cumulative monthly total.
2. **A meaningful denominator**: the allowance for today.

The allowance is not simply `monthlyLimit / totalDays` (a static budget). An honest daily allowance is **adaptive**: it adjusts for over- or under-spending on previous days.

| Metric | Formula | Behavior |
| ---- | ---- | ---- |
| **Static daily budget** | `monthlyLimit / totalDays` | Same every day — ignores past spending pattern |
| **Adaptive daily quota** | `remainingRequests / remainingDays` | Grows when you saved requests yesterday; shrinks when you overspent |

#### Adaptive quota example (same user, day 28)

```log
usedRequests = 1106, monthlyLimit = 1500, remaining days incl. today = 4
  remainingRequests  = 1500 − 1106 = 394
  adaptiveDailyQuota = 394 / 4     = 98 requests today  ← honest budget
  staticDailyBudget  = 1500 / 31   ≈ 48 requests today  ← too conservative
```

The adaptive quota (98) is more than double the static budget (48) because the user has been conservative all month. With a static denominator, the lens hits 100% after just 48 requests, falsely signalling "over budget" when the user actually has 345 requests left in the period.

Both approaches require `todayUsed`, which needs a local **baseline snapshot** — the GitHub API only exposes cumulative monthly totals. The baseline is the cumulative value at the **start of today** (UTC midnight); `todayUsed = currentUsed − baseline`.

---

## Summary of the minimal gap

| # | Gap | Impact |
| ---- | ---- | ---- |
| **1** | `data.quota_snapshots?.premium_interactions` (direct key access) vs `Object.values().find(q => q.quota_id === …)` (value iteration) | Internal API fetch fails for individual licenses → falls back to billing API |
| **2** | Billing API fallback assumes calendar-month period boundaries instead of using `quota_reset_date_utc` | `startOfTodayQuota` is inflated → usage always falls in Zone 1 → lensRatio = 0 → empty today bracket |
| **3** | Uses `quota_remaining` instead of `remaining` | May under-report usage for individual licenses |
| **4** | Lens was computed from cumulative monthly position (Zone 1/2/3), not from intra-day consumption against a per-day allowance | Even with Gaps 1–3 fixed, the lens stays empty for any user in Zone 1 — which includes most conservative users. The correct fix requires (a) a UTC-day baseline snapshot to derive `todayUsed`, and (b) a daily denominator. The ideal denominator is adaptive (`remainingRequests / remainingDays`); the initial implementation uses a static budget (`monthlyLimit / totalDays`) as a simpler first step. |

**Gaps #1 and #2 together were the originally reported root cause.** Fixing them surfaces Gap #4: even with correct API data, the lens stays empty for any user whose cumulative usage falls below `startOfTodayQuota` — which includes most conservative users. The real fix requires (a) a UTC-day baseline in `context.globalState` to track `todayUsed`, and (b) choosing the right daily denominator (static budget vs adaptive quota — see above).

See [design.v4.0.0.today-counter.md](design.v4.0.0.today-counter.md) for the proposed solution design.
