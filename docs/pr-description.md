# Fix today's bracket for individual licenses + adaptive daily quota

Hi! I use an individual Copilot license and hit two issues: the today bracket was always empty, and even after fixing the API parsing, the bracket still did not tell me what I actually needed.

What I require is simple: **at a glance, have I used too many requests /today/?**

Say I have 1500 requests for the month, 3 days left, and I have already used 1108 this month. My fair share for today is roughly `(1500 − 1108) / 3 = 131` requests.

- If I have sent 21 today, I want to see `Today: 21 / 131`: 16% full, I'm fine.
- If I have sent 150 today, the "Today" bracket should be full and bleeding into the future zone.

Here is what I found and what I changed.  
(Disclaimer: with the help of Claude Opus, through GitHub Copilot and my tokens!).

---

## Bug fix: today bracket always empty on individual plans

### What the code does today

[`fetchCopilotInternal` reads `quota_snapshots.premium_interactions`](https://github.com/sergiig/copilot-pacer/blob/b6fe77a6229c9ecc2e7a8060a871f4988e76943d/src/api.ts#L34-L51) as a direct property key. On individual accounts the key appears to be different, so the lookup returns `undefined`, the function throws, and the billing API fallback kicks in.

The billing API fallback has no period dates: it assumes the billing cycle runs from the 1st to the last day of the calendar month. For individual licenses, the actual cycle resets on `quota_reset_date_utc`, which may or may not fall on the 1st. If it does not, the wrong period boundaries inflate `startOfTodayQuota` well past actual usage, and the bracket is stuck empty all day.

Even when the period boundaries happen to be correct (e.g., the quota does reset on the 1st), the billing API data can lag real usage by minutes or hours. Say I have actually sent 1129 requests, but the billing API still reports 1106. That stale number is what the extension uses for `usedRequests`.

And even with a perfectly accurate, real-time `usedRequests`, Zone 1 remains a problem for any conservative user. Here is a concrete example with correct data:

```txt
monthlyLimit  = 1500 requests / 31 days  →  dailyBudget ≈ 48/day
Today: day 29  →  startOfTodayQuota = 28 × 48 = 1344

I have used 1129 cumulative (conservative, ~39/day average: well within budget)
  1129 < 1344  →  Zone 1  →  lensRatio = 0  →  ┃▯▯▯▯▯┃  (always empty)
```

I would need to send 215 more requests today (on top of the 1129 I have already used this month) just for the bracket to start filling. That is before the extension even begins to measure today's usage. The bracket is permanently useless for a conservative user.

### The fix

I looked at how [vscode-copilot-insights does it](https://github.com/kasuken/vscode-copilot-insights/blob/cb388a075c0ab202a1e3990ce0ea317483dabe55/src/extension.ts#L234-L236) and copied the same approach: iterate `Object.values(data.quota_snapshots)` and match on `quota_id === "premium_interactions"` instead of accessing the key directly. That is it: one lookup works regardless of how the API keys the object.

With this fix, `fetchCopilotInternal` succeeds and returns the real `quota_reset_date_utc` as the period end, so `totalDays`, `currentDay`, and all derived quota values are correct.

### While I was there: `quota_remaining` vs `remaining`

The internal API exposes two "remaining" fields per quota snapshot:

- **`quota_remaining`**: clamped at 0 — once you hit the monthly limit it stays at 0, even if you keep sending requests.
- **`remaining`**: the live counter — it goes **below zero** when you exceed the monthly limit (e.g., `−50` means 50 requests past the cap).

**Legacy code:** `const remaining = premium.quota_remaining`  
Because `quota_remaining` is clamped, `usedRequests = entitlement − quota_remaining` can never exceed `entitlement`. At 50 requests into overage you still get `usedRequests = 1500` — the extension never knew you were over budget.

**New code:** `const remaining = premium.remaining`  
Now `usedRequests = entitlement − remaining`. At 50 requests into overage, `remaining = −50` → `usedRequests = 1550`, which correctly exceeds `monthlyLimit = 1500`. The overage cost and the red indicator trigger as intended.

---

## Feature proposal: adaptive daily quota

Even with the API fix working, the Zone 1/2/3 model still did not answer my actual question: *have I used too many requests today?* A user ahead of the monthly pace sits in Zone 1 forever (lens = 0), no matter how many requests they fire that day.

### What I changed

The lens now shows intraday consumption against an adaptive daily budget:

```txt
lensRatio = todayUsed / adaptiveDailyBudget
```

- **`todayUsed`**: requests since UTC midnight, computed as `currentUsed − baseline`. The baseline is stored in `globalState` and rolls over at midnight using the previous day's `lastSeen`, so requests made before VS Code opened are still counted.
- **`adaptiveDailyBudget`**: `remainingRequests / remainingDays`, computed once at day start and frozen for the day, so the denominator does not shrink as you use it. Overspent yesterday? Smaller budget today. Saved some yesterday? Larger budget today.

The GitHub API reports account-wide cumulative usage across all machines, so `todayUsed` automatically includes requests made on other devices: no per-machine tracking needed.

### Two new synced settings

| Key | Shape | Purpose |
| ---- | ---- | ---- |
| `copilot-pacer.dailyBaseline` | `{ date, baseline, lastSeen }` | Day-start baseline + last value for next-day rollover |
| `copilot-pacer.adaptiveQuota` | `{ date, quota }` | Frozen daily budget for the current UTC day |

Both are registered with `setKeysForSync` so VS Code Settings Sync shares them across machines: every device shows the same `Today: X / Y` numbers.

Tooltip gains a `Today: X / Y` line. Color logic updated: orange = over daily budget, red = monthly overage.

---

## Small follow-up for 4.0.1

Testing on April 1 exposed one more local-state bug: even with the fresh-month baseline fixed, the cached adaptive quota could still reuse an old same-day value such as `8` because it only keyed off the UTC date.

The follow-up patch makes two local-state checks in `statusBar.ts`:

- on the first day of a new billing period, reset the stored day baseline to `0` so `todayUsed` starts from the new monthly counter
- only reuse the cached adaptive quota when the date, the billing-period start, and the opening baseline all still match

This keeps `Today: X / Y` correct on the first day of a reset month and ships as version `4.0.1`.

---

Would you be interested in this direction, or do you have a different approach in mind for intraday tracking?
