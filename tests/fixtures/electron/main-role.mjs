import { app, BrowserWindow, dialog, ipcMain, shell } from 'electron';

console.log('app=' + typeof app);
console.log('window=' + typeof BrowserWindow);
console.log('ipc=' + typeof ipcMain.handle);
console.log('dialog=' + typeof dialog.showOpenDialog);
console.log('shell=' + typeof shell.openExternal);

try {
  new BrowserWindow();
  console.log('notready=none');
} catch (err) {
  console.log('notready=' + err.code);
}

await app.whenReady();

try {
  new BrowserWindow({ webPreferences: { contextIsolation: false } });
  console.log('option=none');
} catch (err) {
  console.log('option=' + err.code);
}

try {
  await shell.openExternal('file:///etc/passwd');
  console.log('scheme=none');
} catch (err) {
  console.log('scheme=' + err.name);
}
