// Installs the Node-compatible globals that are built from ESM sources.
import process from 'node:process';

globalThis.process = process;
