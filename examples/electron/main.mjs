import { app, BrowserWindow, dialog, ipcMain } from 'electron';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
let win;

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

await app.whenReady();

ipcMain.handle('pick-file', async (event) => {
  if (event.sender !== win.webContents) throw new Error('unexpected sender');
  return dialog.showOpenDialog(win, {
    title: 'Pick a file',
    properties: ['openFile'],
    filters: [{ name: 'Text', extensions: ['txt', 'md'] }],
  });
});

win = new BrowserWindow({
  width: 720,
  height: 480,
  title: 'jsz desktop example',
  webPreferences: {
    preload: join(here, 'preload.mjs'),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
  },
});

await win.loadFile(join(here, 'index.html'));
