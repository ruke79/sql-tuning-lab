#!/usr/bin/env python3
"""§T-9 전파 워커 — 폴링 방식과 LISTEN/NOTIFY 방식을 같은 코드로 비교하기 위한 클라이언트.

왜 파이썬인가:
  plpgsql 로는 알림을 기다릴 수 없다. pg_sleep() 은 NOTIFY 로 깨지 않으므로
  "알림이 올 때까지 블록"을 서버 안에서 표현할 방법이 없다. 그래서 워커를 클라이언트로
  내보내되, **두 방식이 완전히 같은 코드·같은 denorm_drain() 을 쓰도록** 했다.
  둘을 각각 plpgsql/파이썬으로 짜면 깨우는 방식이 아니라 언어와 왕복 비용을 비교하게 된다.

의존성: psycopg2  (pip install psycopg2-binary)

사용:
  ./t9_worker.py --mode poll   --sleep-ms 20 --batch 2000 --secs 30 --stats /tmp/w.txt
  ./t9_worker.py --mode notify --batch 2000 --secs 30 --stats /tmp/w.txt

--stats 파일에는 "처리배치수 빈폴링수 처리항목수" 를 한 줄로 남긴다.
빈 폴링 수 = 큐가 비어 있는데 깨어나 헛일한 횟수 = 폴링이 낭비하는 왕복.
"""
import argparse, select, signal, time, sys

try:
    import psycopg2, psycopg2.extensions
except ImportError:
    sys.stderr.write("psycopg2 가 필요합니다: pip install psycopg2-binary\n")
    sys.exit(2)

ap = argparse.ArgumentParser()
ap.add_argument('--mode', choices=['poll', 'notify'], default='poll')
ap.add_argument('--sleep-ms', type=float, default=20.0)
ap.add_argument('--batch', type=int, default=2000)
ap.add_argument('--secs', type=float, default=30.0)
ap.add_argument('--host', default='localhost')
ap.add_argument('--port', default='5432')
ap.add_argument('--stats', default='')
a = ap.parse_args()

conn = psycopg2.connect(host=a.host, port=a.port, user='tuner', password='tuner', dbname='tpch')
# autocommit: 배치 하나가 곧 트랜잭션 하나다 (plpgsql 워커의 COMMIT 과 같은 단위).
conn.set_isolation_level(psycopg2.extensions.ISOLATION_LEVEL_AUTOCOMMIT)
cur = conn.cursor()
if a.mode == 'notify':
    cur.execute("LISTEN denorm_q")

deadline = time.monotonic() + a.secs
batches = empty = applied = 0

def write_stats():
    if a.stats:
        with open(a.stats, 'w') as f:
            f.write("%d %d %d\n" % (batches, empty, applied))

# 호출자는 부하가 끝나면 워커를 kill 한다. 그때도 통계를 남겨야 한다 —
# 안 그러면 '빈 폴링 수'가 항상 0 으로 보인다(실제로 그렇게 나와서 알아챘다).
def on_term(_sig, _frm):
    write_stats()
    sys.exit(0)
signal.signal(signal.SIGTERM, on_term)
signal.signal(signal.SIGINT, on_term)

while time.monotonic() < deadline:
    cur.execute("SELECT denorm_drain(%s)", (a.batch,))
    n = cur.fetchone()[0]
    if n:
        batches += 1
        applied += n
        continue

    empty += 1
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break

    if a.mode == 'poll':
        time.sleep(min(a.sleep_ms / 1000.0, remaining))
        continue

    # ── notify: 알림이 올 때까지 블록한다 ──
    # 놓친 알림이 없도록 순서가 중요하다.
    #   1) 이미 도착해 버퍼에 있는 알림을 먼저 확인한다(있으면 즉시 재시도).
    #   2) 없으면 소켓에서 기다린다. drain 과 select 사이에 도착한 알림은
    #      소켓 버퍼에 남아 select 가 곧바로 readable 로 보고하므로 유실되지 않는다.
    # 타임아웃은 깨우는 수단이 아니라 종료 판정용 안전장치일 뿐이다.
    conn.poll()
    if conn.notifies:
        del conn.notifies[:]
        continue
    if select.select([conn], [], [], min(0.5, remaining))[0]:
        conn.poll()
        del conn.notifies[:]

write_stats()
