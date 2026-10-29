// Честная таблица токенов при работе со скиллом (eval/README.md, «Токены»):
// стоимость решения задачи в выходных токенах =
//   w × ядро скилла (SKILL.md в закэшированном system) + c × прочитанные главы + программа;
// w = 0,02 (ядро из кэша) с c = 0,25 (глава — новые входные токены, они
// записываются в кэш) и w = c = 0,2 (без кэша). Строка «главы полным весом» —
// верхняя граница (c = 1, как будто главу пишут). Go, C#, Python, Java и
// JavaScript (Node) модель знает: их спецификация пуста, стоимость — программа. Для сравнения — прежний способ:
// весь docs/KHRIP.md в prompt.
// Программы — код без комментариев (count.mjs), скилл — весь текст файлов.
//
// Запуск: node skill.mjs (из bench/tokens; зависимости — npm install).
import { readFileSync } from 'node:fs';
import { encode as o200k } from 'gpt-tokenizer/encoding/o200k_base';
import { countTokens as claude } from '@anthropic-ai/tokenizer';
import { measure } from './count.mjs';

const root = '../..';
const skill = `${root}/skill/khrip`;
// [w ядра, c глав]
const W = [[0.02, 0.25], [0.2, 0.2]];
const langs = [
  ['Python FastAPI', 'python/main.py'],
  ['C#', 'csharp/Program.cs'],
  ['Go', 'go/main.go'],
  ['Java', 'java/src/main/java/app/App.java'],
  ['Node', 'node/server.js'],
];
const groups = [
  ['Настроечные задачи', ['shortener', 'bank', 'notes', 'ratelimit', 'catalog'], []],
  ['Отложенные задачи', ['inventory', 'polls', 'bookings'], []],
  ['Задачи на PostgreSQL (модель читает главу postgresql.md)', ['ledger', 'shop', 'tracker'], ['postgresql.md']],
];
const metrics = { o200k: (t) => o200k(t).length, claude: (t) => claude(t) };
const raw = (f, m) => metrics[m](readFileSync(f, 'utf8'));
const fmt = (x) => (Number.isInteger(x) ? `${x}` : x.toFixed(0));

for (const m of Object.keys(metrics)) {
  const core = raw(`${skill}/SKILL.md`, m);
  const old = raw(`${root}/docs/KHRIP.md`, m);
  const chapter = (c) => raw(`${skill}/${c}`, m);
  console.log(`\n## ${m === 'o200k' ? 'o200k' : 'Claude (публичный токенизатор)'}\n`);
  console.log(`Ядро SKILL.md — ${core}, postgresql.md — ${chapter('postgresql.md')}, docs/KHRIP.md целиком — ${old}.`);
  for (const [w, c] of W) {
    console.log(`\n### w = ${w}, главы с весом ${c}\n`);
    console.log(`| Задача | Khrip: программа | Khrip со скиллом | ${langs.map(([n]) => n).join(' | ')} |`);
    console.log(`|---|---:|---:|${langs.map(() => '---:').join('|')}|`);
    const all = { prog: 0, cost: 0, costFull: 0, oldCost: 0, others: langs.map(() => 0) };
    for (const [title, tasks, chapters] of groups) {
      const sum = { prog: 0, cost: 0, costFull: 0, oldCost: 0, others: langs.map(() => 0) };
      const ch = chapters.reduce((s, c) => s + chapter(c), 0);
      for (const t of tasks) {
        const prog = measure(`${root}/eval/solutions/${t}/khrip/main.kh`)[m];
        const cost = w * core + c * ch + prog;
        const others = langs.map(([, p]) => measure(`${root}/eval/solutions/${t}/${p}`)[m]);
        sum.prog += prog;
        sum.cost += cost;
        sum.costFull += w * core + ch + prog;
        sum.oldCost += w * old + prog;
        others.forEach((v, i) => (sum.others[i] += v));
        console.log(`| ${t} | ${prog} | ${fmt(cost)} | ${others.join(' | ')} |`);
      }
      const ratio = (v) => (v / sum.cost).toFixed(2);
      console.log(`| **${title}** | **${sum.prog}** | **${fmt(sum.cost)}** | ${sum.others.map((v) => `**${v}** (×${ratio(v)})`).join(' | ')} |`);
      if (chapters.length) console.log(`| то же, главы полным весом (верхняя граница) | | ${fmt(sum.costFull)} | ${sum.others.map((v) => `×${(v / sum.costFull).toFixed(2)}`).join(' | ')} |`);
      console.log(`| то же, прежний способ: KHRIP.md в prompt | | ${fmt(sum.oldCost)} | ${sum.others.map((v) => `×${(v / sum.oldCost).toFixed(2)}`).join(' | ')} |`);
      for (const k of ['prog', 'cost', 'costFull', 'oldCost']) all[k] += sum[k];
      sum.others.forEach((v, i) => (all.others[i] += v));
    }
    const r = (v, base) => `×${(v / base).toFixed(2)}`;
    console.log(`| **Все 11 задач** | **${all.prog}** | **${fmt(all.cost)}** | ${all.others.map((v) => `**${v}** (${r(v, all.cost)})`).join(' | ')} |`);
    console.log(`| то же, главы полным весом (верхняя граница) | | ${fmt(all.costFull)} | ${all.others.map((v) => r(v, all.costFull)).join(' | ')} |`);
    console.log(`| то же, прежний способ: KHRIP.md в prompt | | ${fmt(all.oldCost)} | ${all.others.map((v) => r(v, all.oldCost)).join(' | ')} |`);
  }
}
