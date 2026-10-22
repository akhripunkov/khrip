"""Разбор больших результатов в asyncpg: те же запросы, лучшее из пяти, мс."""
import asyncio
import os
import time

import asyncpg


async def main():
    c = await asyncpg.connect(os.environ["DATABASE_URL"])
    ints = rows = 1e9
    for _ in range(5):
        t0 = time.perf_counter()
        xs = [r[0] for r in await c.fetch("SELECT g FROM generate_series(1, 300000) g")]
        t1 = time.perf_counter()
        rs = await c.fetch("SELECT g AS id, 'name ' || g AS name, repeat('x', 100) AS note FROM generate_series(1, 100000) g")
        t2 = time.perf_counter()
        assert len(xs) == 300000 and len(rs) == 100000
        ints, rows = min(ints, (t1 - t0) * 1000), min(rows, (t2 - t1) * 1000)
    print(f"python\t{ints:.0f}\t{rows:.0f}")
    await c.close()


asyncio.run(main())
