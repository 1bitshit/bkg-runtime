// Copyright (c) 2026 Rithika Liyanage (https://github.com/k-rithik04)
// Licensed under the MIT License - see LICENSE for details
import * as vscode from "vscode";
import { execSync, exec, spawn, type ChildProcess } from "node:child_process";
import * as path from "node:path";
import * as fs from "node:fs";
import * as os from "node:os";
import * as http from "node:http";
import {
  DEBUG_ENV_VAR,
  DEBUG_STATE_KEY,
  FIRST_INSTALL_STATE_KEY,
  MANAGE_COMMAND_ID,
  OPEN_DEBUG_LOG_COMMAND_ID,
  PROVIDER_DISPLAY_NAME,
  SECRET_STORAGE_KEY,
  SHOW_REASONING_STATE_KEY,
  TOGGLE_DEBUG_LOGGING_COMMAND_ID,
  TOGGLE_SHOW_REASONING_COMMAND_ID,
  LAUNCH_CLAUDE_CODE_COMMAND_ID,
  SELECT_DEFAULT_MODEL_COMMAND_ID,
} from "../shared/constants";
import { debugLog, getOutputChannel } from "./output-channel";
import { StatusBarManager } from "./status-bar";
import {
  setShowReasoning,
  setModelsCacheTTL,
  setRequestTimeout,
  setDefaultModel,
} from "../server/index";
import { fetchModels } from "../api";
import { normalizeNvidiaModels } from "../api/model-catalog";
import { buildCustomModelOptions } from "../api/model-options";
import { registerInstallation, checkForUpdates } from "../creator";

let _statusBar: StatusBarManager | null = null;
let _context: vscode.ExtensionContext | null = null;
let _initialized = false;

// ── Bun child process management ───────────────────────────────────────────

let _bunProcess: ChildProcess | null = null;
let _proxyPort = 3456;

function findBun(): string | null {
  try {
    const which = process.platform === "win32" ? "where" : "which";
    return execSync(`${which} bun`, { encoding: "utf8" }).trim().split("\n")[0];
  } catch {
    return null;
  }
}

function isClaudeInstalled(): boolean {
  try {
    const which = process.platform === "win32" ? "where" : "which";
    execSync(`${which} claude`, { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
}

function isProxyRunning(): boolean {
  return _bunProcess !== null && _bunProcess.exitCode === null;
}

async function waitForHealth(
  port: number,
  timeoutMs = 10000,
): Promise<boolean> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      await new Promise<void>((resolve, reject) => {
        const req = http.get(`http://127.0.0.1:${port}/health`, (res) => {
          res.resume();
          if (res.statusCode === 200) resolve();
          else reject(new Error(`status ${res.statusCode}`));
        });
        req.on("error", reject);
        req.setTimeout(2000, () => {
          req.destroy();
          reject(new Error("timeout"));
        });
      });
      return true;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }
  return false;
}

function stopBunProxy(): void {
  if (_bunProcess && !_bunProcess.killed) {
    try {
      if (process.platform === "win32") {
        execSync(`taskkill /pid ${_bunProcess.pid} /T /F`, {
          stdio: "ignore",
        });
      } else {
        _bunProcess.kill("SIGTERM");
      }
    } catch {
      _bunProcess.kill("SIGKILL");
    }
  }
  _bunProcess = null;
}

function startBunProxy(
  port: number,
  apiKey: string,
  defaultModel?: string,
): Promise<void> {
  return new Promise((resolve, reject) => {
    if (_bunProcess) {
      stopBunProxy();
    }

    const bunPath = findBun();
    const cliPath = path.join(_context!.extensionPath, "out", "cli.js");
    const args = [
      cliPath,
      "--serve-only",
      "--port",
      port.toString(),
      "--api-key",
      apiKey,
    ];
    if (defaultModel) {
      args.push("--model", defaultModel);
    }

    let spawnArgs: string[];
    let spawnExec: string;

    if (bunPath) {
      // Bun found — run CLI directly under Bun
      spawnExec = bunPath;
      spawnArgs = args;
    } else {
      // Bun not found — run through sw.ts wrapper which auto-installs Bun
      const swPath = path.join(_context!.extensionPath, "out", "sw.js");
      spawnExec = process.execPath; // Node.js
      spawnArgs = [swPath, ...args];
    }

    debugLog("proxy", `Spawning: ${spawnExec} ${spawnArgs.join(" ")}`);

    _bunProcess = spawn(spawnExec, spawnArgs, {
      stdio: ["ignore", "pipe", "pipe"],
    });
    _proxyPort = port;

    _bunProcess.on("error", (err) => {
      debugLog("proxy", `Proxy process error: ${err.message}`);
      _bunProcess = null;
      reject(err);
    });

    _bunProcess.on("exit", (code) => {
      debugLog("proxy", `Proxy process exited with code ${code}`);
      _bunProcess = null;
    });

    // Wait for server to become healthy
    waitForHealth(port).then((ok) => {
      if (ok) {
        debugLog("proxy", "Server health check passed");
        resolve();
      } else {
        const msg = "Proxy server failed to start within timeout";
        debugLog("proxy", msg);
        stopBunProxy();
        reject(new Error(msg));
      }
    });
  });
}

async function ensureLazyInit(): Promise<void> {
  if (_initialized || !_context) return;
  _initialized = true;

  const ctx = _context;

  // Set debug state from globalState
  const debugEnabled = ctx.globalState.get<boolean>(DEBUG_STATE_KEY, false);
  process.env[DEBUG_ENV_VAR] = debugEnabled ? "1" : "0";
  debugLog(
    "activate",
    `Lazy init complete. Debug logging ${debugEnabled ? "enabled" : "disabled"}.`,
  );

  // Set show-reasoning state
  const showReasoning = ctx.globalState.get<boolean>(
    SHOW_REASONING_STATE_KEY,
    false,
  );
  setShowReasoning(showReasoning);

  // Health check: verify Bun, CLI, and fix any issues
  await postInstallHealthCheck(ctx.extensionPath, ctx.globalState);

  // Register installation and check for updates
  const ghToken = await ctx.secrets.get("nvidia-nim.githubToken");
  void registerInstallation(ghToken || undefined);
  const updateMsg = await checkForUpdates(
    JSON.parse(
      fs.readFileSync(path.join(ctx.extensionPath, "package.json"), "utf8"),
    ).version,
  );
  if (updateMsg) {
    vscode.window.showInformationMessage(updateMsg);
  }

  // Auto-start proxy if key exists
  await tryStartProxy(ctx);
}

function execPromise(
  cmd: string,
  opts?: { timeout?: number },
): Promise<string> {
  return new Promise((resolve, reject) => {
    exec(
      cmd,
      { encoding: "utf8", timeout: opts?.timeout ?? 30_000 },
      (err, stdout) => {
        if (err) reject(err);
        else resolve(stdout.trim());
      },
    );
  });
}

async function createCliShim(extensionPath: string): Promise<boolean> {
  const cliPath = path.join(extensionPath, "out", "cli.js");
  const shimDir = path.join(os.homedir(), ".bun", "bin");

  fs.mkdirSync(shimDir, { recursive: true });

  if (process.platform === "win32") {
    const shimPath = path.join(shimDir, "claude-nim.cmd");
    const newContent = `@echo off\r\nbun "${cliPath}" %*\r\n`;
    const existingContent = fs.existsSync(shimPath)
      ? fs.readFileSync(shimPath, "utf8")
      : "";
    if (existingContent !== newContent) {
      fs.writeFileSync(shimPath, newContent, { mode: 0o755 });
    }
  } else {
    const shimPath = path.join(shimDir, "claude-nim");
    const expectedTarget = cliPath;
    let needsRecreate = true;
    try {
      const currentTarget = fs.readlinkSync(shimPath);
      needsRecreate = currentTarget !== expectedTarget;
    } catch {
      // symlink doesn't exist — create it
    }
    if (needsRecreate) {
      try {
        fs.unlinkSync(shimPath);
      } catch {
        // doesn't exist yet — fine
      }
      fs.symlinkSync(expectedTarget, shimPath);
      fs.chmodSync(shimPath, 0o755);
    }
  }

  return true;
}

async function postInstallHealthCheck(
  extensionPath: string,
  globalState: vscode.Memento,
): Promise<void> {
  if (globalState.get<boolean>(FIRST_INSTALL_STATE_KEY, false)) {
    return;
  }

  const issues: string[] = [];
  const fixed: string[] = [];
  let isFirstInstall = false;

  await vscode.window.withProgress(
    {
      location: vscode.ProgressLocation.Notification,
      title: "Claude-NIM Proxy",
      cancellable: false,
    },
    async (progress) => {
      // ── Step 1: Check Bun ──────────────────────────────────────────────
      progress.report({ message: "Checking Bun runtime..." });
      let bunOk = false;
      try {
        const which = process.platform === "win32" ? "where" : "which";
        await execPromise(`${which} bun`);
        bunOk = true;
      } catch {
        issues.push("Bun runtime not found");
      }

      if (!bunOk) {
        progress.report({ message: "Installing Bun runtime..." });
        try {
          if (process.platform === "win32") {
            await execPromise('powershell -c "irm bun.sh/install.ps1 | iex"', {
              timeout: 120_000,
            });
          } else {
            await execPromise("curl -fsSL https://bun.sh/install | bash", {
              timeout: 120_000,
            });
          }
          try {
            const which = process.platform === "win32" ? "where" : "which";
            await execPromise(`${which} bun`);
            fixed.push("Bun runtime installed");
          } catch {
            issues.push(
              "Bun installed but not found in PATH — add ~/.bun/bin to PATH",
            );
          }
        } catch (err) {
          issues.push(
            `Failed to install Bun: ${err instanceof Error ? err.message : err}`,
          );
        }
      }

      // ── Step 2: Check CLI shim ─────────────────────────────────────────
      progress.report({ message: "Checking Claude-NIM CLI..." });
      let cliOk = false;
      try {
        await execPromise("claude-nim --version", { timeout: 5000 });
        cliOk = true;
      } catch {
        // CLI not found — create shim
      }

      if (!cliOk) {
        progress.report({ message: "Installing Claude-NIM CLI globally..." });
        try {
          await createCliShim(extensionPath);
          // Verify
          try {
            await execPromise("claude-nim --version", { timeout: 5000 });
            fixed.push("Claude-NIM CLI installed");
            cliOk = true;
            isFirstInstall = !globalState.get<boolean>(
              FIRST_INSTALL_STATE_KEY,
              false,
            );
            await globalState.update(FIRST_INSTALL_STATE_KEY, true);
          } catch {
            issues.push(
              "CLI shim created but not found in PATH — restart your terminal",
            );
          }
        } catch (err) {
          issues.push(
            `Failed to create CLI shim: ${err instanceof Error ? err.message : err}`,
          );
        }
      }

      // ── Step 3: Verify CLI works end-to-end ────────────────────────────
      if (cliOk || fixed.some((f) => f.includes("CLI"))) {
        progress.report({ message: "Verifying CLI works..." });
        try {
          const version = await execPromise("claude-nim --version", {
            timeout: 5000,
          });
          debugLog("healthCheck", `CLI version: ${version}`);
        } catch {
          issues.push("CLI installed but failed to run");
        }
      }
    },
  );

  // ── Report ─────────────────────────────────────────────────────────────
  const unresolved = issues.filter(
    (i) =>
      !fixed.some((f) =>
        f.toLowerCase().includes(i.split(" ")[0].toLowerCase()),
      ),
  );
  if (unresolved.length === 0) {
    vscode.window.showInformationMessage(
      `Claude-NIM: Successfully installed!${fixed.length > 0 ? " (" + fixed.join(", ") + ")" : ""}`,
    );
  } else {
    const msg =
      `Claude-NIM install issues:\n` +
      unresolved.map((i) => `  - ${i}`).join("\n") +
      (fixed.length > 0 ? `\nFixed: ${fixed.join(", ")}` : "");
    vscode.window.showWarningMessage(msg);
  }

  // ── Welcome message on first install ───────────────────────────────────
  if (isFirstInstall) {
    const action = await vscode.window.showInformationMessage(
      "Claude NIM installed! Open a new terminal and type `claude-nim` to start.",
      "Open Terminal",
    );
    if (action === "Open Terminal") {
      const terminal = vscode.window.createTerminal({
        name: "Claude NIM",
      });
      terminal.show();
    }
  }
}

function syncModelToClaudeSettings(modelId: string): void {
  try {
    const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
    let cfg: Record<string, unknown> = {};
    if (fs.existsSync(settingsPath)) {
      cfg = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    }
    cfg.model = modelId;
    fs.writeFileSync(settingsPath, JSON.stringify(cfg, null, 2), "utf8");
  } catch {
    // Best-effort — settings write is non-critical
  }
}

function isValidNimKey(key: string): boolean {
  return key.startsWith("nvapi-") && key.length > 10;
}

async function tryStartProxy(
  context: vscode.ExtensionContext,
  showMessage = false,
): Promise<void> {
  if (isProxyRunning()) {
    if (showMessage) {
      vscode.window.showInformationMessage(
        "Claude Code Proxy is already running.",
      );
    }
    return;
  }

  const apiKey = await context.secrets.get(SECRET_STORAGE_KEY);

  // Check if key exists and is valid format
  if (!apiKey || !isValidNimKey(apiKey)) {
    _statusBar?.updateApiKeyStatus(false);
    // Prompt for API key
    const newKey = await vscode.window.showInputBox({
      title: `${PROVIDER_DISPLAY_NAME} API Key`,
      prompt: apiKey
        ? "Invalid key format. NVIDIA NIM keys start with 'nvapi-'"
        : "Enter your NVIDIA NIM API key to get started",
      ignoreFocusOut: true,
      password: true,
      placeHolder: "nvapi-...",
    });
    if (!newKey?.trim()) {
      if (showMessage) {
        vscode.window.showErrorMessage(
          "API key is required to start the proxy.",
        );
      }
      return;
    }
    if (!isValidNimKey(newKey.trim())) {
      vscode.window.showErrorMessage(
        "Invalid key format. NVIDIA NIM keys start with 'nvapi-'.",
      );
      return;
    }
    await context.secrets.store(SECRET_STORAGE_KEY, newKey.trim());
    _statusBar?.updateApiKeyStatus(true);
    // Continue with the newly stored key
    return tryStartProxy(context, showMessage);
  }

  _statusBar?.updateApiKeyStatus(true);

  const config = vscode.workspace.getConfiguration("nvidia-nim");
  const port = config.get<number>("proxyPort", 3456);
  const defaultModel = config.get<string>("defaultModel", "");
  if (defaultModel) {
    syncModelToClaudeSettings(defaultModel);
  }
  const showReasoning = context.globalState.get<boolean>(
    SHOW_REASONING_STATE_KEY,
    false,
  );
  const cacheTTL = config.get<number>("modelsCacheTTL", 5);
  const requestTimeout = config.get<number>("requestTimeout", 120);

  setShowReasoning(showReasoning);
  setModelsCacheTTL(cacheTTL);
  setRequestTimeout(requestTimeout);
  setDefaultModel(defaultModel || undefined);

  try {
    await startBunProxy(port, apiKey, defaultModel || undefined);
    _statusBar?.update(true, port, defaultModel || undefined);
    vscode.window.showInformationMessage(
      `${PROVIDER_DISPLAY_NAME} Proxy started on port ${port}`,
    );
  } catch (err) {
    const msg = `Failed to start proxy: ${err instanceof Error ? err.message : err}`;
    vscode.window.showErrorMessage(msg);
    _statusBar?.update(false);
  }
}

function stopProxy(showMessage = false): void {
  if (!isProxyRunning()) {
    if (showMessage) {
      vscode.window.showInformationMessage("Claude Code Proxy is not running.");
    }
    return;
  }

  stopBunProxy();
  _statusBar?.update(false);
  vscode.window.showInformationMessage(
    `${PROVIDER_DISPLAY_NAME} Proxy stopped`,
  );
}

export async function activate(context: vscode.ExtensionContext) {
  _context = context;

  const channel = getOutputChannel();
  context.subscriptions.push(channel);

  _statusBar = new StatusBarManager();
  context.subscriptions.push(_statusBar);

  // Check API key status on activation
  const hasApiKey = !!(await context.secrets.get(SECRET_STORAGE_KEY));
  _statusBar.updateApiKeyStatus(hasApiKey);

  // Post-install health check: verify Bun, CLI, and fix any issues (background)
  void postInstallHealthCheck(context.extensionPath, context.globalState);

  // Register all commands — they trigger lazy init on first use
  context.subscriptions.push(
    vscode.commands.registerCommand(MANAGE_COMMAND_ID, async () => {
      await ensureLazyInit();
      const existing = await context.secrets.get(SECRET_STORAGE_KEY);
      const apiKey = await vscode.window.showInputBox({
        title: `${PROVIDER_DISPLAY_NAME} API Key`,
        prompt: existing
          ? `Update your ${PROVIDER_DISPLAY_NAME} API key`
          : `Enter your ${PROVIDER_DISPLAY_NAME} API key`,
        ignoreFocusOut: true,
        password: true,
        value: existing ?? "",
        placeHolder: `Enter your ${PROVIDER_DISPLAY_NAME} API key...`,
      });
      if (apiKey === undefined) {
        return;
      }
      if (!apiKey.trim()) {
        await context.secrets.delete(SECRET_STORAGE_KEY);
        vscode.window.showInformationMessage(
          `${PROVIDER_DISPLAY_NAME} API key cleared.`,
        );
        stopProxy();
        return;
      }
      await context.secrets.store(SECRET_STORAGE_KEY, apiKey.trim());
      vscode.window.showInformationMessage(
        `${PROVIDER_DISPLAY_NAME} API key saved.`,
      );
      stopProxy();
      await tryStartProxy(context);
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      TOGGLE_DEBUG_LOGGING_COMMAND_ID,
      async () => {
        await ensureLazyInit();
        const current = context.globalState.get<boolean>(
          DEBUG_STATE_KEY,
          false,
        );
        const next = !current;
        await context.globalState.update(DEBUG_STATE_KEY, next);
        process.env[DEBUG_ENV_VAR] = next ? "1" : "0";
        debugLog(
          "toggleDebug",
          `Debug logging ${next ? "enabled" : "disabled"}.`,
        );
        vscode.window.showInformationMessage(
          `${PROVIDER_DISPLAY_NAME} debug logging ${next ? "enabled" : "disabled"}.`,
        );
      },
    ),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      TOGGLE_SHOW_REASONING_COMMAND_ID,
      async () => {
        await ensureLazyInit();
        const current = context.globalState.get<boolean>(
          SHOW_REASONING_STATE_KEY,
          false,
        );
        const next = !current;
        await context.globalState.update(SHOW_REASONING_STATE_KEY, next);
        setShowReasoning(next);
        vscode.window.showInformationMessage(
          `${PROVIDER_DISPLAY_NAME} model reasoning output is now ${next ? "visible" : "hidden"}.`,
        );
      },
    ),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(OPEN_DEBUG_LOG_COMMAND_ID, async () => {
      await ensureLazyInit();
      const output = getOutputChannel();
      output.show(true);
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("nvidia-nim.toggleProxy", async () => {
      await ensureLazyInit();
      if (isProxyRunning()) {
        stopProxy(true);
      } else {
        await tryStartProxy(context, true);
      }
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(LAUNCH_CLAUDE_CODE_COMMAND_ID, async () => {
      await ensureLazyInit();
      if (!isProxyRunning()) {
        await tryStartProxy(context, true);
      }

      // Ensure Claude Code CLI is installed
      if (!isClaudeInstalled()) {
        const install = await vscode.window.showWarningMessage(
          "Claude Code CLI is not installed. Install it now?",
          "Install",
          "Cancel",
        );
        if (install === "Install") {
          try {
            await new Promise<void>((res, rej) => {
              exec(
                "bun install -g @anthropic-ai/claude-code",
                { timeout: 120_000 },
                (err: Error | null) => {
                  if (err) rej(err);
                  else res();
                },
              );
            });
            vscode.window.showInformationMessage("Claude Code installed.");
          } catch {
            vscode.window.showErrorMessage(
              "Failed to install Claude Code. Run: bun install -g @anthropic-ai/claude-code",
            );
            return;
          }
        } else {
          return;
        }
      }

      const apiKey = await context.secrets.get(SECRET_STORAGE_KEY);
      if (!apiKey) {
        vscode.window.showErrorMessage(
          "Cannot launch Claude Code without an API key.",
        );
        return;
      }

      const config = vscode.workspace.getConfiguration("nvidia-nim");
      const port = config.get<number>("proxyPort", 3456);
      const defaultModel = config.get<string>("defaultModel", "");
      if (defaultModel) {
        syncModelToClaudeSettings(defaultModel);
      }

      let customModelOption = "[]";
      try {
        const rawModels = await fetchModels(apiKey);
        if (rawModels) {
          const models = normalizeNvidiaModels(rawModels);
          customModelOption = buildCustomModelOptions(models);
        }
      } catch {
        // Launch without custom models if fetch fails
      }

      const terminal = vscode.window.createTerminal({
        name: "Claude Code (NVIDIA NIM)",
        env: {
          ANTHROPIC_BASE_URL: `http://127.0.0.1:${port}`,
          ANTHROPIC_API_KEY: apiKey,
          CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY: "1",
          ANTHROPIC_CUSTOM_MODEL_OPTION: customModelOption,
          ANTHROPIC_AUTH_TOKEN: "",
        },
      });
      terminal.show();
      terminal.sendText("claude");
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand(
      SELECT_DEFAULT_MODEL_COMMAND_ID,
      async () => {
        await ensureLazyInit();
        const apiKey = await context.secrets.get(SECRET_STORAGE_KEY);
        if (!apiKey) {
          vscode.window.showErrorMessage(
            "Please configure your NVIDIA NIM API key first.",
          );
          return;
        }

        const modelsResponse = await fetchModels(apiKey);
        if (!modelsResponse) {
          vscode.window.showErrorMessage(
            "Failed to fetch models from NVIDIA NIM.",
          );
          return;
        }

        const models = normalizeNvidiaModels(modelsResponse);
        const items = models.map((m) => ({
          label: m.displayName,
          description: m.id,
          detail: `Context Window: ${m.contextWindow.toLocaleString()} tokens`,
          modelId: m.id,
        }));

        const selected = await vscode.window.showQuickPick(items, {
          placeHolder: "Select a default model for Claude Code",
          matchOnDescription: true,
        });

        if (selected) {
          const config = vscode.workspace.getConfiguration("nvidia-nim");
          await config.update(
            "defaultModel",
            selected.modelId,
            vscode.ConfigurationTarget.Global,
          );
          syncModelToClaudeSettings(selected.modelId);
          vscode.window.showInformationMessage(
            `Default model set to ${selected.label}. Synced to Claude Code settings.`,
          );
        }
      },
    ),
  );

  // Configuration change listener — react to all setting changes
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (!e.affectsConfiguration("nvidia-nim")) return;

      const config = vscode.workspace.getConfiguration("nvidia-nim");

      if (e.affectsConfiguration("nvidia-nim.proxyPort")) {
        if (isProxyRunning()) {
          stopProxy();
          void tryStartProxy(context);
        }
        return;
      }

      const cacheTTL = config.get<number>("modelsCacheTTL", 5);
      setModelsCacheTTL(cacheTTL);

      const requestTimeout = config.get<number>("requestTimeout", 120);
      setRequestTimeout(requestTimeout);

      const defaultModel = config.get<string>("defaultModel", "");
      setDefaultModel(defaultModel || undefined);
    }),
  );
}

function spawnCleanupScript(): void {
  if (process.platform === "win32") {
    const psLines = [
      'Write-Host ""',
      'Write-Host "  Thank you for using Claude-NIM!" -ForegroundColor Cyan',
      'Write-Host ""',
      'Write-Host "  Cleaning up Claude-NIM traces..." -ForegroundColor Yellow',
      'Write-Host ""',
      "",
      "# Remove CLI shim and aliases",
      '$shimDir = Join-Path (Join-Path "$env:USERPROFILE" ".bun") "bin"',
      'Get-ChildItem $shimDir -Filter "claude-nim*" -ErrorAction SilentlyContinue | ForEach-Object {',
      "    Remove-Item -Force $_.FullName -ErrorAction SilentlyContinue",
      '    Write-Host ("  Removed: " + $_.Name) -ForegroundColor DarkGray',
      "}",
      "",
      "# Remove API key file",
      '$keyFile = Join-Path "$env:USERPROFILE" ".claude-nim-key"',
      "if (Test-Path $keyFile) {",
      "    Remove-Item -Force $keyFile -ErrorAction SilentlyContinue",
      '    Write-Host "  Removed API key file" -ForegroundColor DarkGray',
      "}",
      "",
      "# Npm global uninstall",
      'try { npm uninstall -g claude-nim 2>&1 | Out-Null; Write-Host "  Uninstalled global npm package" -ForegroundColor DarkGray } catch { }',
      "",
      "# Bun global uninstall",
      'try { bun uninstall -g claude-nim 2>&1 | Out-Null; Write-Host "  Uninstalled global bun package" -ForegroundColor DarkGray } catch { }',
      "",
      "# Cleanup model from Claude settings",
      '$claudeSettings = Join-Path (Join-Path "$env:USERPROFILE" ".claude") "settings.json"',
      "if (Test-Path $claudeSettings) {",
      "    try {",
      "        $cfg = Get-Content $claudeSettings -Raw | ConvertFrom-Json",
      '        if ($cfg.PSObject.Properties.Name -contains "model") {',
      '            $cfg.PSObject.Properties.Remove("model")',
      "            $cfg | ConvertTo-Json | Set-Content $claudeSettings",
      '            Write-Host "  Cleaned Claude settings" -ForegroundColor DarkGray',
      "        }",
      "    } catch { }",
      "}",
      "",
      'Write-Host ""',
      'Write-Host "  Claude-NIM has been fully removed from your system." -ForegroundColor Green',
      'Write-Host ""',
      'Read-Host "  Press Enter to close this window"',
    ];
    const psScript = psLines.join("\r\n");
    const scriptPath = path.join(os.tmpdir(), "claude-nim-cleanup.ps1");
    try {
      fs.writeFileSync(scriptPath, psScript, "utf8");
      const child = exec(
        `start "Claude NIM Cleanup" powershell -NoExit -ExecutionPolicy Bypass -File "${scriptPath}"`,
      );
      child?.unref();
    } catch {
      // best-effort
    }
  } else {
    const shLines = [
      '#!/usr/bin/env bash',
      'echo ""',
      'echo "  Thank you for using Claude-NIM!"',
      'echo ""',
      'echo "  Cleaning up Claude-NIM traces..."',
      'echo ""',
      "",
      "# Remove CLI symlinks",
      "for name in claude-nim Claude-nim CLAUDE-NIM Claude-Nim; do",
      '  target="$HOME/.bun/bin/$name"',
      '  if [ -L "$target" ] || [ -f "$target" ]; then',
      '    rm -f "$target" 2>/dev/null',
      '    echo "  Removed: $name"',
      "  fi",
      "done",
      "",
      "# Remove API key file",
      '[ -f "$HOME/.claude-nim-key" ] && rm -f "$HOME/.claude-nim-key" && echo "  Removed API key file" || true',
      "",
      "# Npm global uninstall",
      'npm uninstall -g claude-nim 2>/dev/null && echo "  Uninstalled global npm package" || true',
      "",
      "# Bun global uninstall",
      'bun uninstall -g claude-nim 2>/dev/null && echo "  Uninstalled global bun package" || true',
      "",
      "# Cleanup Claude settings",
      'if [ -f "$HOME/.claude/settings.json" ]; then',
      '  node -e \'const fs=require("fs");const p=process.env.HOME+"/.claude/settings.json";const c=JSON.parse(fs.readFileSync(p,"utf8"));delete c.model;fs.writeFileSync(p,JSON.stringify(c,null,2));\' 2>/dev/null && echo "  Cleaned Claude settings" || true',
      "fi",
      "",
      'echo ""',
      'echo "  Claude-NIM has been fully removed from your system."',
      'echo ""',
      'read -rp "  Press Enter to close this window "',
    ];
    const shScript = shLines.join("\n");
    const scriptPath = path.join(os.tmpdir(), "claude-nim-cleanup.sh");
    try {
      fs.writeFileSync(scriptPath, shScript, "utf8");
      fs.chmodSync(scriptPath, 0o755);
      if (process.platform === "darwin") {
        const child = exec(`open -a Terminal "${scriptPath}"`);
        child?.unref();
      } else {
        const child = exec(`x-terminal-emulator -e "${scriptPath}"`);
        child?.unref();
      }
    } catch {
      // best-effort
    }
  }
}

export function deactivate() {
  spawnCleanupScript();
  stopBunProxy();
  _statusBar = null;
  _context = null;
  _initialized = false;
}
