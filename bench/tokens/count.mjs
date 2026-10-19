// Сколько токенов занимает одна и та же программа на разных языках.
// Считается только код: полные строки-комментарии, комментарии в конце строки
// и пустые строки убираются, чтобы сравнивать то, что модель должна написать.
//
// Токенизаторы: o200k_base (OpenAI GPT-4o и новее), cl100k_base (GPT-4) и
// публичный токенизатор Anthropic (@anthropic-ai/tokenizer, предыдущие модели
// Claude; токенизатор нынешних моделей не опубликован).
//
// Запуск: node count.mjs <файл>...
import { readFileSync } from 'node:fs';
import { encode as o200k } from 'gpt-tokenizer/encoding/o200k_base';
import { encode as cl100k } from 'gpt-tokenizer/encoding/cl100k_base';
import { countTokens as claude } from '@anthropic-ai/tokenizer';

function stripComments(text) {
  return text
    .split('\n')
    .filter((line) => !line.trim().startsWith('//'))
    .map((line) => line.replace(/\s+\/\/.*$/, '').trimEnd())
    .filter((line) => line.length > 0)
    .join('\n');
}

const rows = process.argv.slice(2).map((file) => {
  const code = stripComments(readFileSync(file, 'utf8'));
  return {
    file,
    lines: code.split('\n').length,
    chars: code.length,
    o200k: o200k(code).length,
    cl100k: cl100k(code).length,
    claude: claude(code),
  };
});

console.log('| Файл | Строк | Символов | o200k | cl100k | Claude (публичный) |');
console.log('|---|---:|---:|---:|---:|---:|');
for (const r of rows) {
  console.log(`| ${r.file} | ${r.lines} | ${r.chars} | ${r.o200k} | ${r.cl100k} | ${r.claude} |`);
}
