// Решение на Node в двух процессах node:cluster: node eval/node_cluster.mjs server.js
// (eval/server.sh, язык node-cluster). Главный процесс принимает соединения и
// раздаёт их рабочим по очереди. Данные в памяти рабочие не делят, поэтому так
// запускаются только задачи с базой (ledger, shop, tracker).
import cluster from 'node:cluster'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

if (cluster.isPrimary) {
  for (let i = 0; i < 2; i++) cluster.fork()
  cluster.on('exit', () => process.exit(1))
} else {
  await import(pathToFileURL(resolve(process.argv[2])).href)
}
