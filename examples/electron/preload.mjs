import { contextBridge, ipcRenderer } from 'electron';

contextBridge.exposeInMainWorld('desktop', {
  pickFile: () => ipcRenderer.invoke('pick-file'),
});
