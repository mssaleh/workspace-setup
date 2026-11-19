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
  const packageRules = Object.entries(baseline.permission.bash);
  if (Object.hasOwn(config, 'permissions')) {
    if (!Array.isArray(config.permissions)) throw new Error('OpenCode permissions must be an array');
    const required = packageRules.map(([resource, effect]) => ({ action: 'shell', resource, effect }));
    const tail = config.permissions.slice(-required.length);
    // OpenCode V2 uses the last matching rule. Keep other rules in their original order.
    const matches = tail.length === required.length && required.every((rule, index) => {
      const entry = tail[index];
      return entry?.action === rule.action && entry.resource === rule.resource && entry.effect === rule.effect;
    });
    if (!matches) {
      for (const rule of required) set(['permissions', -1], rule);
    }
  } else {
    const permission = config.permission;
    if (typeof permission === 'string') set(['permission'], { '*': permission });
    const bash = permission && typeof permission === 'object' ? permission.bash : undefined;
    if (typeof bash === 'string') set(['permission', 'bash'], { '*': bash });
    for (const [command, policy] of packageRules) {
      if (!bash || bash[command] !== policy) set(['permission', 'bash', command], policy);
    }
  }
  process.stdout.write(text);
} else {
  throw new Error(`Unknown configuration operation: ${action}`);
}
