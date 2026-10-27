// Installs the Node-compatible globals that are built from ESM sources.
import process from 'node:process';
import { Buffer, atob, btoa } from 'node:buffer';
import { TextEncoder, TextDecoder } from 'node:util';
import { webcrypto } from 'node:crypto';
import { URL, URLSearchParams } from 'node:url';

globalThis.process = process;
globalThis.Buffer = Buffer;
globalThis.atob = atob;
globalThis.btoa = btoa;
globalThis.TextEncoder = TextEncoder;
globalThis.TextDecoder = TextDecoder;
globalThis.crypto = webcrypto;
globalThis.URL = URL;
globalThis.URLSearchParams = URLSearchParams;
