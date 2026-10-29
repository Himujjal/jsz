import * as native from 'node:_sea';

export function isSea() {
  return native.isSea();
}

export function getAssetKeys() {
  return native.getAssetKeys();
}

export function getRawAsset(key) {
  return native.getAsset(key);
}

export function getAsset(key, encoding) {
  const buffer = native.getAsset(key);
  if (encoding === undefined) return buffer;
  return new TextDecoder(encoding).decode(new Uint8Array(buffer));
}
