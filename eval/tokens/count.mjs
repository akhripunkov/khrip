// Токены o200k (OpenAI GPT-4o и новее) в решениях задач eval на Khrip — до и
// после изменения: «до» — те же файлы в git-ревизии --base, «после» — рабочее
// дерево. Считается только код, как в bench/tokens/count.mjs: строки-
// комментарии, комментарии в конце строки и пустые строки убираются.
//
//   eval/tokens/run.sh                    # 11 решений: --base e1203ad и сейчас
//   eval/tokens/run.sh --base HEAD~3      # другая точка отсчёта
//   eval/tokens/run.sh --pairs eval/tokens/protocols   # пары X.before.kh / X.after.kh
//   eval/tokens/run.sh --files a.kh b.kh  # просто файлы
//   eval/tokens/run.sh --raw skill/khrip/*.md   # весь текст, с комментариями:
//                                         # так его читает модель (скилл)
//
// protocols/ — программы P1–P4 из docs/design/v0.14-protocols.md, §16.1
// (X.before.kh — как там, X.after.kh — с анонимными типами и литералами,
// приложение A). В них синтаксис v0.14 (stream, send, rpc, topic): их считают,
// а не собирают.
//
// run.sh один раз ставит gpt-tokenizer 2.9.0 (package.json) — тот же
// токенизатор, что у bench/tokens; нужен Node.js 18+ и git.
import { execFileSync } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { encode } from 'gpt-tokenizer/encoding/o200k_base';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '../..');

// как stripComments в bench/tokens/count.mjs (файлы Khrip: комментарии — //)
export function code(text) {
  return text
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .map((line) => line.replace(/\s+\/\/.*$/, '').trimEnd())
    .filter((line) => line.length > 0)
    .join('\n');
}

export function tokens(text) {
  return encode(code(text)).length;
}

function atRev(rev, path) {
  try {
    return execFileSync('git', ['-C', root, 'show', `${rev}:${path}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  } catch {
    return null;
  }
}

function pct(before, after) {
  return `${(((after - before) / before) * 100).toFixed(1)}%`;
}

function table(rows) {
  console.log('| | before | after | Δ | Δ % |');
  console.log('|---|---:|---:|---:|---:|');
  let sb = 0;
  let sa = 0;
  for (const [name, b, a] of rows) {
    sb += b;
    sa += a;
    console.log(`| ${name} | ${b} | ${a} | ${a - b} | ${pct(b, a)} |`);
  }
  console.log(`| **total** | **${sb}** | **${sa}** | **${sa - sb}** | **${pct(sb, sa)}** |`);
}

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
};

if (args.includes('--raw')) {
  for (const f of args.slice(args.indexOf('--raw') + 1)) {
    console.log(`${encode(readFileSync(f, 'utf8')).length}\t${f}`);
  }
} else if (args.includes('--files')) {
  for (const f of args.slice(args.indexOf('--files') + 1)) {
    console.log(`${tokens(readFileSync(f, 'utf8'))}\t${f}`);
  }
} else if (args.includes('--pairs')) {
  const dir = opt('--pairs');
  const names = readdirSync(dir).filter((f) => f.endsWith('.before.kh')).map((f) => f.slice(0, -'.before.kh'.length)).sort();
  table(names.map((n) => [n, tokens(readFileSync(join(dir, `${n}.before.kh`), 'utf8')), tokens(readFileSync(join(dir, `${n}.after.kh`), 'utf8'))]));
} else {
  const base = opt('--base', 'e1203ad');
  const sol = join(root, 'eval/solutions');
  const rows = [];
  for (const task of readdirSync(sol).sort()) {
    const path = `eval/solutions/${task}/khrip/main.kh`;
    if (!existsSync(join(root, path))) continue;
    const old = atRev(base, path);
    if (old === null) continue;
    rows.push([task, tokens(old), tokens(readFileSync(join(root, path), 'utf8'))]);
  }
  console.log(`o200k, eval/solutions/*/khrip/main.kh: ${base} → working tree\n`);
  table(rows);
}
