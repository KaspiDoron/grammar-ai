import * as vscode from "vscode";
import { CorrectionContext, CorrectionError, Mode } from "./correction";
import { ClaudeCodeProvider, FailoverProvider, OllamaProvider, Provider } from "./providers";

let diagnostics: vscode.DiagnosticCollection;
let statusBar: vscode.StatusBarItem;
let output: vscode.LogOutputChannel;

/** A pending correction the quick-fix can apply, keyed by document + range. */
interface Suggestion {
  range: vscode.Range;
  original: string;
  corrected: string;
}
const suggestionsByDoc = new Map<string, Suggestion[]>();
const debounceTimers = new Map<string, NodeJS.Timeout>();

export function activate(context: vscode.ExtensionContext): void {
  diagnostics = vscode.languages.createDiagnosticCollection("grammarAI");
  output = vscode.window.createOutputChannel("Grammar AI", { log: true });
  statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 50);
  statusBar.command = "grammarAI.fixSelection";
  context.subscriptions.push(diagnostics, output, statusBar);

  context.subscriptions.push(
    vscode.commands.registerCommand("grammarAI.fixSelection", fixSelection),
    vscode.commands.registerCommand("grammarAI.fixDocument", fixDocument),
    vscode.commands.registerCommand("grammarAI.toggleAsYouType", toggleAsYouType),
    vscode.commands.registerCommand("grammarAI.applySuggestion", applySuggestion),
    vscode.languages.registerCodeActionsProvider("*", new GrammarQuickFix(), {
      providedCodeActionKinds: [vscode.CodeActionKind.QuickFix],
    }),
    vscode.workspace.onDidChangeTextDocument((e) => scheduleAsYouType(e.document)),
    vscode.window.onDidChangeActiveTextEditor(() => refreshStatusBar()),
    vscode.workspace.onDidCloseTextDocument((doc) => {
      diagnostics.delete(doc.uri);
      suggestionsByDoc.delete(doc.uri.toString());
    })
  );

  refreshStatusBar();
  void showWelcomeIfFirstRun(context);
}

/// The first time the extension runs, tell the user in plain words how to use
/// it - this is what makes it discoverable instead of a silent install.
async function showWelcomeIfFirstRun(context: vscode.ExtensionContext): Promise<void> {
  const key = "grammarAI.welcomed.v1";
  if (context.globalState.get<boolean>(key)) return;
  await context.globalState.update(key, true);
  const shortcut = process.platform === "darwin" ? "Cmd+Shift+G" : "Ctrl+Shift+G";
  const choice = await vscode.window.showInformationMessage(
    `Typfix is ready. Select text and press ${shortcut} to fix its grammar - free, on your Mac.`,
    "Try it now",
    "Settings"
  );
  if (choice === "Try it now") {
    // Open a scratch doc with a wrong sentence, select it, and correct it.
    const doc = await vscode.workspace.openTextDocument({
      language: "markdown",
      content: "i dont think this is working properly, but lets see if typfix can fixed it",
    });
    const editor = await vscode.window.showTextDocument(doc);
    editor.selection = new vscode.Selection(doc.positionAt(0), doc.positionAt(doc.getText().length));
    await vscode.commands.executeCommand("grammarAI.fixSelection");
  } else if (choice === "Settings") {
    await vscode.commands.executeCommand("workbench.action.openSettings", "grammarAI");
  }
}

export function deactivate(): void {
  for (const timer of debounceTimers.values()) clearTimeout(timer);
}

// --- Configuration ---

function buildProvider(): Provider {
  const config = vscode.workspace.getConfiguration("grammarAI");
  const kind = config.get<string>("provider", "free");
  const ollama = new OllamaProvider({
    host: config.get<string>("ollama.host", "http://localhost:11434"),
    model: config.get<string>("ollama.model", "qwen3:1.7b"),
  });
  const claude = new ClaudeCodeProvider(config.get<string>("claudeCode.path", ""));
  switch (kind) {
    case "ollama":
      return ollama;
    case "claudeCode":
      return claude;
    case "free":
    default:
      return new FailoverProvider([ollama, claude]);
  }
}

function correctionContext(): CorrectionContext {
  return { mode: vscode.workspace.getConfiguration("grammarAI").get<Mode>("mode", "natural") };
}

// --- Commands ---

async function fixSelection(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return;
  const selection = editor.selection.isEmpty ? paragraphRange(editor.document, editor.selection.active) : editor.selection;
  const text = editor.document.getText(selection);
  if (!text.trim()) {
    vscode.window.setStatusBarMessage("$(info) Grammar AI: nothing to correct here", 3000);
    return;
  }
  await runCorrection(editor, selection, text);
}

async function fixDocument(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) return;
  const full = new vscode.Range(
    editor.document.positionAt(0),
    editor.document.positionAt(editor.document.getText().length)
  );
  const text = editor.document.getText();
  if (!text.trim()) return;
  await runCorrection(editor, full, text);
}

async function runCorrection(editor: vscode.TextEditor, range: vscode.Range, text: string): Promise<void> {
  await vscode.window.withProgress(
    { location: vscode.ProgressLocation.Window, title: "Grammar AI: correcting..." },
    async () => {
      const controller = new AbortController();
      try {
        const result = await buildProvider().correct(text, correctionContext(), controller.signal);
        if (!result.changed) {
          vscode.window.setStatusBarMessage("$(check) Grammar AI: already looks good", 3000);
          return;
        }
        if (result.needsReview) {
          const choice = await vscode.window.showWarningMessage(
            "This is a big rewrite. Apply it?",
            { modal: true, detail: result.correctedText },
            "Apply"
          );
          if (choice !== "Apply") return;
        }
        // A single edit = one native undo step.
        const applied = await editor.edit((builder) => builder.replace(range, result.correctedText));
        if (applied) {
          vscode.window.setStatusBarMessage("$(check) Grammar AI: corrected", 2500);
          // A fixed range no longer has a pending suggestion.
          clearSuggestionAt(editor.document, range);
        } else {
          vscode.window.showErrorMessage("Grammar AI couldn't apply the correction.");
        }
      } catch (err) {
        showError(err);
      }
    }
  );
}

function toggleAsYouType(): void {
  const config = vscode.workspace.getConfiguration("grammarAI");
  const now = !config.get<boolean>("asYouType.enabled", false);
  config.update("asYouType.enabled", now, vscode.ConfigurationTarget.Global);
  vscode.window.showInformationMessage(`Grammar AI: as-you-type suggestions ${now ? "on" : "off"}.`);
  if (!now) diagnostics.clear();
}

// --- As-you-type suggestions ---

function scheduleAsYouType(document: vscode.TextDocument): void {
  const config = vscode.workspace.getConfiguration("grammarAI");
  if (!config.get<boolean>("asYouType.enabled", false)) return;
  if (!appliesTo(document)) return;
  const editor = vscode.window.activeTextEditor;
  if (!editor || editor.document !== document) return;

  const key = document.uri.toString();
  const existing = debounceTimers.get(key);
  if (existing) clearTimeout(existing);
  const delay = config.get<number>("asYouType.delayMs", 1200);
  const cursor = editor.selection.active;
  debounceTimers.set(
    key,
    setTimeout(() => {
      debounceTimers.delete(key);
      void checkParagraph(document, cursor);
    }, delay)
  );
}

async function checkParagraph(document: vscode.TextDocument, near: vscode.Position): Promise<void> {
  const range = paragraphRange(document, near);
  const text = document.getText(range);
  if (text.trim().length < 4) return;
  try {
    const result = await buildProvider().correct(text, correctionContext(), AbortSignal.timeout(30000));
    if (!result.changed || result.needsReview) {
      replaceSuggestions(document, range, undefined);
      return;
    }
    replaceSuggestions(document, range, { range, original: text, corrected: result.correctedText });
  } catch (err) {
    // As-you-type failures are silent except in the log; the manual command
    // still surfaces errors to the user.
    if (err instanceof CorrectionError && err.kind !== "cancelled") {
      output.debug(`as-you-type: ${err.kind}: ${err.message}`);
    }
  }
}

function replaceSuggestions(document: vscode.TextDocument, range: vscode.Range, suggestion: Suggestion | undefined): void {
  const key = document.uri.toString();
  const kept = (suggestionsByDoc.get(key) ?? []).filter((s) => !s.range.intersection(range));
  if (suggestion) kept.push(suggestion);
  suggestionsByDoc.set(key, kept);

  diagnostics.set(
    document.uri,
    kept.map((s) => {
      const diagnostic = new vscode.Diagnostic(
        s.range,
        "Grammar AI suggests a fix.",
        vscode.DiagnosticSeverity.Information
      );
      diagnostic.source = "Grammar AI";
      diagnostic.code = "grammar-suggestion";
      return diagnostic;
    })
  );
}

class GrammarQuickFix implements vscode.CodeActionProvider {
  provideCodeActions(document: vscode.TextDocument, range: vscode.Range): vscode.CodeAction[] {
    const suggestions = suggestionsByDoc.get(document.uri.toString()) ?? [];
    const actions: vscode.CodeAction[] = [];
    for (const suggestion of suggestions) {
      if (!suggestion.range.intersection(range)) continue;
      const action = new vscode.CodeAction("Apply grammar fix", vscode.CodeActionKind.QuickFix);
      action.edit = new vscode.WorkspaceEdit();
      action.edit.replace(document.uri, suggestion.range, suggestion.corrected);
      action.isPreferred = true;
      action.command = {
        command: "grammarAI.applySuggestion",
        title: "Apply grammar fix",
        arguments: [document.uri.toString(), suggestion.range],
      };
      actions.push(action);
    }
    return actions;
  }
}

function applySuggestion(uriString: string, range: vscode.Range): void {
  // The edit is applied by the code-action itself; this just clears the mark.
  const key = uriString;
  const kept = (suggestionsByDoc.get(key) ?? []).filter((s) => !s.range.isEqual(range));
  suggestionsByDoc.set(key, kept);
  const uri = vscode.Uri.parse(uriString);
  const document = vscode.workspace.textDocuments.find((d) => d.uri.toString() === uriString);
  if (document) replaceSuggestions(document, range, undefined);
  else diagnostics.delete(uri);
}

function clearSuggestionAt(document: vscode.TextDocument, range: vscode.Range): void {
  replaceSuggestions(document, range, undefined);
}

// --- Helpers ---

function appliesTo(document: vscode.TextDocument): boolean {
  const ids = vscode.workspace.getConfiguration("grammarAI").get<string[]>("languageIds", []);
  return ids.includes("*") || ids.includes(document.languageId);
}

/** The block of non-blank lines around a position - one "paragraph". */
function paragraphRange(document: vscode.TextDocument, position: vscode.Position): vscode.Range {
  let start = position.line;
  let end = position.line;
  const blank = (line: number) => document.lineAt(line).isEmptyOrWhitespace;
  if (blank(start)) return new vscode.Range(position.line, 0, position.line, document.lineAt(position.line).text.length);
  while (start > 0 && !blank(start - 1)) start--;
  while (end < document.lineCount - 1 && !blank(end + 1)) end++;
  return new vscode.Range(start, 0, end, document.lineAt(end).text.length);
}

async function refreshStatusBar(): Promise<void> {
  statusBar.text = "$(sparkle) Grammar AI";
  statusBar.tooltip = "Grammar AI: fix grammar in the selection (Cmd+Shift+G)";
  statusBar.show();
  try {
    const status = await buildProvider().available();
    statusBar.text = status.ok ? "$(sparkle) Grammar AI" : "$(warning) Grammar AI";
    statusBar.tooltip = `Grammar AI - ${status.detail}\nCmd+Shift+G to fix the selection`;
  } catch {
    // leave the default
  }
}

function showError(err: unknown): void {
  if (err instanceof CorrectionError) {
    if (err.kind === "cancelled") return;
    vscode.window.showErrorMessage(`Grammar AI: ${err.message}`);
  } else {
    vscode.window.showErrorMessage(`Grammar AI: ${String(err)}`);
  }
}
