try {
  await import('electron');
  console.log('electron=loaded');
} catch (err) {
  console.log('electron=' + err.code);
}

try {
  await import('node:electron');
  console.log('node=loaded');
} catch (err) {
  console.log('node=' + err.code);
}
