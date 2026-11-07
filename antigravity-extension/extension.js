// Pi Companion — tells the Pi desktop pet which project you're working on,
// so Pi can save "where I left off" to PiNotes when you close the project.
const vscode = require('vscode');

let statusItem;
let heartbeat;
let editTimer;
let cursorTimer;
let announced = false;      // has Pi received our "open" event yet?
let contextFile = null;     // path Pi told us the CONTEXT.md lives at

function port() {
  return vscode.workspace.getConfiguration('piCompanion').get('port', 47615);
}

function workspace() {
  const folders = vscode.workspace.workspaceFolders;
  if (!folders || !folders.length || folders[0].uri.scheme !== 'file') return null;
  return folders[0];
}

function snapshot(event, active) {
  const ws = workspace();
  if (!ws) return null;
  const ed = vscode.window.activeTextEditor;
  const doc = ed && ed.document.uri.scheme === 'file' ? ed.document : null;
  const selection = ed && !ed.selection.isEmpty ? ed.document.getText(ed.selection).slice(0, 4000) : '';
  const openFiles = [];
  for (const group of vscode.window.tabGroups.all) {
    for (const tab of group.tabs) {
      const uri = tab.input && tab.input.uri;
      if (uri && uri.scheme === 'file' && !openFiles.includes(uri.fsPath)) openFiles.push(uri.fsPath);
    }
  }
  return {
    editor: vscode.env.appName,
    event,
    active,
    workspaceName: ws.name,
    workspacePath: ws.uri.fsPath,
    activeFile: doc ? doc.uri.fsPath : '',
    cursorLine: ed ? ed.selection.active.line + 1 : 0,
    selection,
    openFiles: openFiles.slice(0, 30),
  };
}

async function post(route, body, timeoutMs = 4000) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const res = await fetch(`http://127.0.0.1:${port()}${route}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: ctrl.signal,
    });
    setStatus(true);
    return await res.json();
  } catch (e) {
    if (e.name !== 'AbortError') setStatus(false);
    return null;
  } finally {
    clearTimeout(timer);
  }
}

async function sendState(event, active) {
  const snap = snapshot(announced ? event : 'open', active);
  if (!snap) return;
  const res = await post('/v1/state', snap);
  if (res && res.ok) {
    announced = true;
    if (res.contextFile) contextFile = res.contextFile;
  }
}

function setStatus(online) {
  if (!statusItem) return;
  statusItem.text = online ? '🥧 Pi' : '🥧 Pi (offline)';
  statusItem.tooltip = online
    ? 'Pi saves where you left off when you close this project. Click to see the last saved context.'
    : 'Pi desktop app is not running. Start PiePet.app to track progress.';
}

async function openContext() {
  if (!contextFile) await sendState('focus', false);
  if (!contextFile) return vscode.window.showWarningMessage('Pi: the Pi app is not running.');
  try {
    await vscode.workspace.fs.stat(vscode.Uri.file(contextFile));
  } catch {
    return vscode.window.showInformationMessage("Pi hasn't saved a context for this project yet.");
  }
  openFile(contextFile);
}

async function saveNote() {
  const ed = vscode.window.activeTextEditor;
  let body = ed && !ed.selection.isEmpty ? ed.document.getText(ed.selection) : '';
  if (body && ed) {
    const lang = ed.document.languageId;
    const rel = vscode.workspace.asRelativePath(ed.document.uri);
    body = `From \`${rel}\` line ${ed.selection.start.line + 1}:\n\n\`\`\`${lang}\n${body}\n\`\`\``;
  } else {
    body = await vscode.window.showInputBox({ prompt: 'Note text' });
    if (!body) return;
  }
  const title = await vscode.window.showInputBox({ prompt: 'Note title', value: 'Code note' });
  if (title === undefined) return;
  const res = await post('/v1/note', { title, body });
  if (res && res.ok) vscode.window.showInformationMessage('Pi saved your note to PiNotes.');
  else vscode.window.showErrorMessage('Pi: could not save the note. Is the Pi app running?');
}

function openFile(p) {
  vscode.window.showTextDocument(vscode.Uri.file(p), { preview: true });
}

function activate(context) {
  statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
  statusItem.command = 'piCompanion.openContext';
  setStatus(false);
  statusItem.show();

  context.subscriptions.push(
    statusItem,
    vscode.commands.registerCommand('piCompanion.openContext', openContext),
    vscode.commands.registerCommand('piCompanion.saveNote', saveNote),

    vscode.workspace.onDidChangeTextDocument((e) => {
      if (e.document.uri.scheme !== 'file' || !e.contentChanges.length) return;
      clearTimeout(editTimer);
      editTimer = setTimeout(() => sendState('edit', true), 5000);
    }),
    vscode.workspace.onDidSaveTextDocument((d) => {
      if (d.uri.scheme === 'file') sendState('save', true);
    }),
    vscode.window.onDidChangeActiveTextEditor(() => sendState('focus', true)),
    vscode.window.onDidChangeTextEditorSelection(() => {
      clearTimeout(cursorTimer);
      cursorTimer = setTimeout(() => sendState('cursor', true), 10000);
    }),
    vscode.workspace.onDidChangeWorkspaceFolders(() => {
      announced = false;
      sendState('open', false);
    }),
  );

  sendState('open', false);
  heartbeat = setInterval(() => sendState('heartbeat', false), 60000);
}

// Runs when the window/project closes: ask Pi to save where we left off.
// Pi keeps writing even after we stop waiting for the reply.
function deactivate() {
  clearInterval(heartbeat);
  const snap = snapshot('close', false);
  if (!snap) return undefined;
  return post('/v1/save', { ...snap, reason: 'close' }, 2500);
}

module.exports = { activate, deactivate };
