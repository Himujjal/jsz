import { app, BrowserWindow, ipcMain } from 'electron';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
let win;

ipcMain.handle('echo', (event, value) => {
  if (event.sender !== win.webContents) throw new Error('unexpected sender');
  return { value, url: win.webContents.getURL() };
});

ipcMain.handle('report', (event, text) => {
  if (event.sender !== win.webContents) throw new Error('unexpected sender');
  console.log('desktop=' + text);
  app.quit();
  return null;
});

app.on('window-all-closed', () => {});

// Keep the harness bounded if the bridge never reaches the page.
setTimeout(() => {
  console.log('desktop=timeout');
  app.exit(2);
}, 20000);

await app.whenReady();

win = new BrowserWindow({
  width: 480,
  height: 320,
  title: 'jsz electron fixture',
  webPreferences: {
    preload: join(here, 'preload.mjs'),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
  },
});

await win.loadFile(join(here, 'index.html'));
