const fs = require('node:fs');
const { parse, modify, applyEdits } = require('jsonc-parser');

const [action, destination, source] = process.argv.slice(2);
let text = fs.readFileSync(destination, 'utf8');
const errors = [];
const config = parse(text, errors, { allowTrailingComma: true });
if (errors.length || !config || Array.isArray(config) || typeof config !== 'object') {
  throw new Error('Invalid OpenCode configuration');
}
if (action === 'read') {
  process.stdout.write(JSON.stringify(config));
} else if (action === 'merge') {
  const baseline = JSON.parse(fs.readFileSync(source, 'utf8'));
  const set = (path, value) => {
    text = applyEdits(text, modify(text, path, value, {
      formattingOptions: { insertSpaces: true, tabSize: 2 },
    }));
  };
  if (!Object.hasOwn(config, '$schema')) set(['$schema'], baseline.$schema);
  const permission = config.permission;
  if (typeof permission === 'string') set(['permission'], { '*': permission });
  const bash = permission && typeof permission === 'object' ? permission.bash : undefined;
  if (typeof bash === 'string') set(['permission', 'bash'], { '*': bash });
  for (const [command, policy] of Object.entries(baseline.permission.bash)) {
    if (!bash || bash[command] !== policy) set(['permission', 'bash', command], policy);
  }
  process.stdout.write(text);
} else {
  throw new Error(`Unknown configuration operation: ${action}`);
}
