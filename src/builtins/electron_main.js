// Electron-shaped main-process facade for `jsz --desktop`.
//
// This is a scoped compatibility layer, not an Electron runtime. Every
// privileged operation is validated here and then performed by the native
// WebUI backend through `node:_electron_main`.

import * as native from 'node:_electron_main';
import EventEmitter from 'node:events';

function invalidArgType(name, expected, value) {
  let received;
  if (value === null) received = 'null';
  else if (Array.isArray(value)) received = 'an array';
  else if (typeof value === 'object') {
    const type = value.constructor && value.constructor.name;
    received = type ? `an instance of ${type}` : 'an object';
  } else received = `${typeof value} (${String(value)})`;

  const error = new TypeError(`The "${name}" argument must be of type ${expected}. Received ${received}`);
  error.code = 'ERR_INVALID_ARG_TYPE';
  return error;
}

function validateString(value, name) {
  if (typeof value !== 'string') throw invalidArgType(name, 'string', value);
  return value;
}

function validateChannel(channel) {
  validateString(channel, 'channel');
  if (channel.length === 0) throw invalidArgType('channel', 'non-empty string', channel);
  if (channel.startsWith('jsz:')) {
    const error = new Error(`The channel "${channel}" is reserved`);
    error.code = 'ERR_IPC_CHANNEL_RESERVED';
    throw error;
  }
  return channel;
}

function unsupportedOption(name) {
  const error = new Error(`The option "${name}" is not supported by the jsz desktop backend`);
  error.code = 'ERR_ELECTRON_UNSUPPORTED_OPTION';
  return error;
}

function makeEvent() {
  return {
    defaultPrevented: false,
    preventDefault() {
      this.defaultPrevented = true;
    },
  };
}

const windows = new Map();

class WebContents extends EventEmitter {
  constructor(window) {
    super();
    this._window = window;
  }

  send(channel, ...args) {
    validateChannel(channel);
    if (this._window.isDestroyed()) {
      const error = new Error('The window is destroyed');
      error.code = 'ERR_WINDOW_CLOSED';
      throw error;
    }
    native.send(this._window._id, channel, JSON.stringify(args));
  }

  getURL() {
    return native.getUrl(this._window._id);
  }

  isDestroyed() {
    return this._window.isDestroyed();
  }
}

class BrowserWindow extends EventEmitter {
  constructor(options = {}) {
    super();
    if (!app.isReady()) {
      const error = new Error('The application is not ready');
      error.code = 'ERR_APP_NOT_READY';
      throw error;
    }
    if (options === null || typeof options !== 'object') {
      throw invalidArgType('options', 'object', options);
    }

    const width = options.width === undefined ? 800 : options.width;
    const height = options.height === undefined ? 600 : options.height;
    if (!Number.isInteger(width) || width <= 0) throw unsupportedOption('width');
    if (!Number.isInteger(height) || height <= 0) throw unsupportedOption('height');

    const title = options.title === undefined ? '' : options.title;
    validateString(title, 'title');
    const show = options.show === undefined ? true : options.show;
    const resizable = options.resizable === undefined ? true : options.resizable;
    if (typeof show !== 'boolean') throw invalidArgType('show', 'boolean', show);
    if (typeof resizable !== 'boolean') throw invalidArgType('resizable', 'boolean', resizable);

    const webPreferences = options.webPreferences === undefined ? {} : options.webPreferences;
    if (webPreferences === null || typeof webPreferences !== 'object') {
      throw invalidArgType('webPreferences', 'object', webPreferences);
    }
    if (webPreferences.contextIsolation !== undefined && webPreferences.contextIsolation !== true) {
      throw unsupportedOption('webPreferences.contextIsolation');
    }
    if (webPreferences.nodeIntegration !== undefined && webPreferences.nodeIntegration !== false) {
      throw unsupportedOption('webPreferences.nodeIntegration');
    }
    if (webPreferences.sandbox !== undefined && webPreferences.sandbox !== true) {
      throw unsupportedOption('webPreferences.sandbox');
    }
    let preload = null;
    if (webPreferences.preload !== undefined) {
      preload = validateString(webPreferences.preload, 'webPreferences.preload');
      if (!preload.startsWith('/')) throw unsupportedOption('webPreferences.preload must be an absolute path');
    }

    const id = native.createWindow(width, height, show, resizable, title);
    this._id = id;
    this._destroyed = false;
    this._closed = false;
    this._preload = preload;
    this.webContents = new WebContents(this);
    windows.set(id, this);
  }

  static getAllWindows() {
    return [...windows.values()];
  }

  async loadFile(filePath) {
    validateString(filePath, 'filePath');
    await native.loadFile(this._id, filePath, this._preload === null ? undefined : this._preload);
  }

  async loadURL(url) {
    validateString(url, 'url');
    await native.loadUrl(this._id, url);
  }

  show() {
    native.show(this._id);
  }

  hide() {
    native.hide(this._id);
  }

  close() {
    if (this._closed) return;
    const event = makeEvent();
    this.emit('close', event);
    if (event.defaultPrevented) return;
    native.close(this._id);
    this._finalizeClose();
  }

  destroy() {
    if (this._closed) return;
    native.destroy(this._id);
    this._finalizeClose();
  }

  isDestroyed() {
    return this._closed || native.isDestroyed(this._id);
  }

  isVisible() {
    return !this._closed && native.isVisible(this._id);
  }

  setTitle(title) {
    validateString(title, 'title');
    native.setTitle(this._id, title);
  }

  _finalizeClose() {
    if (this._closed) return;
    this._closed = true;
    this._destroyed = true;
    windows.delete(this._id);
    this.emit('closed');
    if (windows.size === 0) app.emit('window-all-closed');
  }
}

class Application extends EventEmitter {
  constructor() {
    super();
    this._ready = false;
    this._quitting = false;
    this._hasActivated = false;
  }

  whenReady() {
    this._ready = true;
    return Promise.resolve();
  }

  isReady() {
    return this._ready;
  }

  getVersion() {
    return native.getVersion();
  }

  quit() {
    if (this._quitting) return;
    this._quitting = true;

    const before = makeEvent();
    this.emit('before-quit', before);
    if (before.defaultPrevented) {
      this._quitting = false;
      return;
    }

    for (const window of [...windows.values()]) window.close();
    if (windows.size > 0) {
      this._quitting = false;
      return;
    }

    const will = makeEvent();
    this.emit('will-quit', will);
    if (will.defaultPrevented) {
      this._quitting = false;
      return;
    }

    this.emit('quit', {}, 0);
    native.quit();
  }

  exit(code = 0) {
    native.exit(code | 0);
  }
}

const app = new Application();

const ipcHandlers = new Map();
const ipcListeners = new Map();

const ipcMain = {
  handle(channel, listener) {
    validateChannel(channel);
    if (typeof listener !== 'function') throw invalidArgType('listener', 'function', listener);
    if (ipcHandlers.has(channel)) {
      const error = new Error(`Attempted to register a second handler for '${channel}'`);
      error.code = 'ERR_IPC_HANDLER_EXISTS';
      throw error;
    }
    ipcHandlers.set(channel, listener);
  },

  removeHandler(channel) {
    ipcHandlers.delete(validateChannel(channel));
  },

  on(channel, listener) {
    validateChannel(channel);
    if (typeof listener !== 'function') throw invalidArgType('listener', 'function', listener);
    if (!ipcListeners.has(channel)) ipcListeners.set(channel, []);
    ipcListeners.get(channel).push(listener);
    return this;
  },

  removeListener(channel, listener) {
    const listeners = ipcListeners.get(channel);
    if (listeners) {
      const index = listeners.indexOf(listener);
      if (index >= 0) listeners.splice(index, 1);
      if (listeners.length === 0) ipcListeners.delete(channel);
    }
    return this;
  },
};

const dialog = {
  async showOpenDialog(browserWindow, options) {
    if (browserWindow instanceof BrowserWindow) {
      // Window modality is not exposed by the WebUI picker; the window is
      // accepted for signature compatibility only.
      options = options === undefined ? {} : options;
    } else {
      options = browserWindow === undefined ? {} : browserWindow;
    }
    if (options === null || typeof options !== 'object') {
      throw invalidArgType('options', 'object', options);
    }
    const result = await native.showOpenDialog(JSON.stringify(options));
    return JSON.parse(result);
  },
};

const shell = {
  async openExternal(url) {
    validateString(url, 'url');
    await native.openExternal(url);
  },
};

globalThis.__jszTrack = (promise, resolve, reject) => Promise.resolve(promise).then(resolve, reject);

globalThis.__jszDispatchIpc = async (requestId, windowId, channel, argsJson) => {
  const handler = ipcHandlers.get(channel);
  const window = windows.get(windowId);
  if (!window) {
    const error = new Error('The window is closed');
    error.code = 'ERR_WINDOW_CLOSED';
    throw error;
  }
  if (!handler) {
    const error = new Error(`No handler registered for '${channel}'`);
    error.code = 'ERR_IPC_NO_HANDLER';
    throw error;
  }

  const args = JSON.parse(argsJson || '[]');
  const result = await handler({ sender: window.webContents }, ...args);
  return JSON.stringify(result === undefined ? null : result);
};

globalThis.__jszDispatchIpcSend = (windowId, payloadJson) => {
  const payload = JSON.parse(payloadJson);
  const window = windows.get(windowId);
  if (!window) return;
  const listeners = ipcListeners.get(payload.channel);
  if (!listeners) return;
  for (const listener of [...listeners]) {
    try {
      listener({ sender: window.webContents }, ...(payload.args || []));
    } catch (error) {
      console.error(error);
    }
  }
};

globalThis.__jszDesktopEvent = (name, payloadJson) => {
  const payload = payloadJson ? JSON.parse(payloadJson) : {};
  if (name === 'did-finish-load') {
    const window = windows.get(payload.id);
    if (window) window.webContents.emit('did-finish-load');
  } else if (name === 'window-closed') {
    const window = windows.get(payload.id);
    if (window) window._finalizeClose();
  } else if (name === 'window-show') {
    const window = windows.get(payload.id);
    if (window) window.emit('show');
  }
};

export { app, BrowserWindow, ipcMain, dialog, shell };
