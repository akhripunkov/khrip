// Сколько токенов занимает файл целиком (для docs/KHRIP.md: его кладут в промпт).
import { readFileSync } from 'node:fs';
import { encode as o200k } from 'gpt-tokenizer/encoding/o200k_base';
import { countTokens as claude } from '@anthropic-ai/tokenizer';

for (const file of process.argv.slice(2)) {
  const text = readFileSync(file, 'utf8');
  console.log(`${file}: o200k ${o200k(text).length}, Claude ${claude(text)}`);
}
