# Test: Local testing of the today-bracket fix

Related plan: [plan.v4.0.0.today-counter.md](plan.v4.0.0.today-counter.md)

---

## Prerequisites

### Node.js and npm

The project declares `"@types/node": "22.x"` in its devDependencies, so you need **Node.js 22 LTS** (the current LTS line as of 2026). Any 22.x release works (e.g., 22.15.0).

**npm is bundled with Node.js** — you do not need to install it separately. Node 22 LTS ships with npm 10.x.

Download from: <https://nodejs.org/> (pick the LTS installer for Windows).

After installation, verify in a **new** terminal:

```powershell
node --version   # should print v22.x.x
npm --version    # should print 10.x.x
```

### Where are dependencies installed?

`npm install` installs packages **locally inside the project**, in a `copilot-pacer/node_modules/` folder. It does **not** modify your global Node.js installation. Each project has its own isolated `node_modules/` — this is the Node.js equivalent of a Python venv.

> **Note:** Node.js does not need a virtual environment like Python's `venv`. The `node_modules/` directory is already per-project by default. There is nothing extra to activate or deactivate — just `cd` into the project and run `npm install`.

### VS Code

VS Code 1.109 or later (the extension declares `"engines": { "vscode": "^1.109.0" }`).

---

## Step 1 — Install dependencies

Open a terminal in the extension folder and install:

```powershell
cd C:\Users\xxx\prog\git\copilot-trackers\copilot-pacer
npm install
```

This creates a `node_modules/` folder inside `copilot-pacer/` with all devDependencies (TypeScript compiler, type definitions, ESLint, etc.). The folder is gitignored.

---

## Step 2 — Compile the extension

```powershell
npm run compile
```

This runs `tsc -p ./` and produces JavaScript files in the `out/` directory.

---

## Step 3 — Do I need to uninstall the Marketplace version?

**Yes.** If you have the official "Pacer for GitHub Copilot" (`sergiig.copilot-pacer`) installed from the Marketplace, you must **disable or uninstall** it first. Two extensions with the same identifier cannot coexist — VS Code will load one and ignore the other, and the Marketplace version takes precedence over a dev install.

To uninstall from the command line:

```powershell
code --uninstall-extension sergiig.copilot-pacer
```

Or from within VS Code: **Extensions** sidebar → search "Pacer" → **Uninstall**.

---

## Step 4 — Launch via the Extension Development Host (recommended)

This is the easiest way. It launches a **separate VS Code window** with your local extension loaded — no packaging required.

1. Open the extension folder in VS Code:

   ```powershell
   code C:\Users\xxx\prog\git\copilot-trackers\copilot-pacer
   ```

2. Press **F5** (or **Run → Start Debugging**).  
   This launches a new VS Code window titled **"[Extension Development Host]"** with the extension loaded from `out/`.

3. In that new window, open any project and use Copilot as normal. The status bar should show the pacer indicator. Trigger a refresh (`Ctrl+Shift+P` → "Pacer: Refresh") and verify the today bracket fills correctly.

> **Tip:** The `watch` script (`npm run watch`) recompiles on every save. Run it in a separate terminal so you only need to reload the Development Host window (`Ctrl+R`) after each change.

### Checking the version running in the Extension Development Host

When you press **F5** the extension is **not installed** — VS Code loads it directly from the `out/` folder of the project you opened. There is no separate "installed" copy. The version is always whatever is in [package.json](../package.json).

To confirm:
- Check `package.json` in the project root: `"version": "4.0.0"`.
- The Extensions sidebar (**Ctrl+Shift+X**) in the EDH window lists the extension with that same version, but this reflects `package.json`, not an installation record.

### Settings initialization in the Extension Development Host

Pressing **F5** is sufficient to bootstrap both `globalState` settings — no separate step is needed. The extension calls `updatePacing()` immediately on activation (before any user interaction). As soon as the first GitHub API response arrives (~1–2 seconds after the EDH window opens), both `copilot-pacer.dailyBaseline` and `copilot-pacer.adaptiveQuota` are written. The EDH uses the **same user data directory** as your regular VS Code session, so these values land in the same store that Settings Sync monitors and will propagate to other machines normally.

---

## Step 5 — Install as a VSIX on your current machine (real VS Code session)

If you want to test inside your **normal** VS Code session (not a Development Host), you need to package and install the extension as a `.vsix` file.

### 5a — Install the packaging tool

```powershell
npm install -g @vscode/vsce
```

### 5b — Package the extension

```powershell
cd C:\Users\xxx\prog\git\copilot-trackers\copilot-pacer
vsce package
```

This produces a file like `copilot-pacer-4.0.0.vsix` in the current directory.

### 5c — Install the VSIX

```powershell
code --install-extension copilot-pacer-4.0.0.vsix
```

Or from within VS Code: **Extensions** sidebar → **⋯** menu (top-right) → **Install from VSIX…** → select the `.vsix` file.

### 5d — Reload VS Code

After installing, reload the window: `Ctrl+Shift+P` → **Developer: Reload Window**.

---

## Step 6 — Use on other machines (same GitHub account)

Because this build has not yet been published to the VS Code Marketplace (it is pending a pull request to the upstream extension), you need to bring the extension to each machine manually. Two approaches exist.

### Approach A — Compile from source on the other machine (recommended)

This avoids transferring a binary and gives you a clean build matched to that machine's environment.

#### 6a — Clone the fork on the other machine

```bash
git clone https://github.com/<your-fork>/copilot-pacer.git
cd copilot-pacer
```

If you have no fork yet, clone the upstream repo and apply the diff:

```bash
git clone https://github.com/sergiig/copilot-pacer.git
cd copilot-pacer
git apply a.diff   # patch file at the root of the project
```

#### 6b — Install dependencies and compile

```powershell
npm install
npm run compile
```

This produces the `out/` directory.

#### 6c — Run via Extension Development Host (fastest, no install needed)

Open the folder in VS Code and press **F5**. The extension runs directly from `out/` — no packaging required. See Step 4 above for details.

#### 6d — Or package and install as VSIX

If you prefer a fully installed extension on that machine:

```powershell
npm install -g @vscode/vsce
vsce package
code --install-extension copilot-pacer-4.0.0.vsix
```

### Approach B — Copy the VSIX from your current machine

If the other machine cannot run `npm` (e.g. a restricted environment), copy the `.vsix` file you already built in Step 5.

#### 6e — Transfer the VSIX

Copy `copilot-pacer-4.0.0.vsix` by any means (USB drive, shared folder, `scp`, etc.) and install:

```powershell
code --install-extension copilot-pacer-4.0.0.vsix
```

Or from within VS Code: **Extensions** sidebar → **⋯** menu → **Install from VSIX…**.

Reload VS Code when prompted.

### 6f — Enable VS Code Settings Sync on the other machine

The extension stores both the day baseline and the adaptive quota in `context.globalState` and registers them for VS Code **Settings Sync**. For all machines to show the same `Today: X / Y` count, Settings Sync must be active on each machine.

To enable it: `Ctrl+Shift+P` → **Settings Sync: Turn On** → sign in with the same GitHub (or Microsoft) account you use for Copilot.

> **Note:** Settings Sync is optional. Without it, each machine computes its own baseline and adaptive quota at UTC midnight. The today counter still works locally; it just won't reflect requests made on the other machine until the two instances sync.

### 6g — When the PR is merged

Once the upstream author accepts the pull request and publishes a new version to the Marketplace, you can uninstall the local build and switch back to the auto-updating Marketplace release:

```powershell
code --uninstall-extension sergiig.copilot-pacer
code --install-extension sergiig.copilot-pacer
```

---

## Step 7 — Verify the fix

| What to check | How |
| ---- | ---- |
| **Internal API succeeds** | Open the Output panel (`Ctrl+Shift+U`) → select **Pacer for GitHub Copilot** from the dropdown. There should be no fallback-to-billing error. |
| **Adaptive quota logged** | The Output panel should show a line like `[adaptive quota] remaining=394 / 3 days → 131/day` on the first refresh of each UTC day. |
| **Today bracket fills** | The status bar should show `┃▮…┃` with partial fill (not all-empty `┃▯▯▯▯▯┃`). |
| **Month bracket still works** | The past zone `▰▱` should show the same proportional fill as before. |
| **Token counter still works** | Send a Copilot chat message and confirm the token counter increments. |

---

## Cleanup \u2014 Restoring the Marketplace version (current machine only)

When done testing the local VSIX on your current machine, uninstall it and reinstall the official version from the Marketplace:

```powershell
code --uninstall-extension sergiig.copilot-pacer
code --install-extension sergiig.copilot-pacer
```

Or from the Extensions sidebar: uninstall, then search **Pacer for GitHub Copilot** and reinstall.
