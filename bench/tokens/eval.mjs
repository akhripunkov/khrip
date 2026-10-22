// Таблица токенов решений из eval/solutions: задача × язык (o200k и Claude).
// Запуск: node eval.mjs (из bench/tokens).
import { existsSync, readdirSync } from 'node:fs';
import { measure } from './count.mjs';

const root = '../../eval/solutions';
const langs = [
  ['Khrip', 'khrip/main.kh'],
  ['Python FastAPI', 'python/main.py'],
  ['C#', 'csharp/Program.cs'],
  ['Go', 'go/main.go'],
];
// Задачи, на которых язык дорабатывался (v0.9), и отложенные: написаны после того,
// как язык был заморожен, — по ним видно, обобщаются ли доработки.
const groups = [
  ['Настроечные задачи (язык дорабатывался на них)', ['shortener', 'bank', 'notes', 'ratelimit', 'catalog']],
  ['Отложенные задачи (язык не менялся)', ['inventory', 'polls', 'bookings']],
  ['Задачи на PostgreSQL (v0.12)', ['ledger', 'shop', 'tracker']],
];
const known = groups.flatMap(([, ts]) => ts);
const extra = readdirSync(root).filter((t) => !known.includes(t)).sort();
if (extra.length) groups.push(['Другие задачи', extra]);

for (const metric of ['o200k', 'claude']) {
  console.log(`\n## ${metric === 'o200k' ? 'o200k (GPT-4o и новее)' : 'Claude (публичный токенизатор)'}`);
  for (const [title, tasks] of groups) {
    console.log(`\n${title}\n`);
    console.log(`| Задача | ${langs.map(([n]) => n).join(' | ')} |`);
    console.log(`|---|${langs.map(() => '---:').join('|')}|`);
    const sums = langs.map(() => 0);
    for (const task of tasks) {
      const cells = langs.map(([, path], i) => {
        const file = `${root}/${task}/${path}`;
        if (!existsSync(file)) return '—';
        const m = measure(file);
        sums[i] += m[metric];
        return m[metric];
      });
      const best = Math.min(...cells.filter((c) => typeof c === 'number'));
      console.log(`| ${task} | ${cells.map((c) => (c === best ? `**${c}**` : c)).join(' | ')} |`);
    }
    console.log(`| всего | ${sums.join(' | ')} |`);
    console.log(`| к Khrip | ${sums.map((s) => (s / sums[0]).toFixed(2)).join(' | ')} |`);
  }
}
