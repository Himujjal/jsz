import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('desktop', {
  echo: (value) => ipcRenderer.invoke('echo', value),
  report: (text) => ipcRenderer.invoke('report', text),
});
