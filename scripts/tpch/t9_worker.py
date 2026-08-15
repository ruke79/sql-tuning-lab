#!/usr/bin/env python3
"""§T-9 전파 워커 — 폴링 방식과 LISTEN/NOTIFY 방식을 같은 코드로 비교하기 위한 클라이언트.

왜 파이썬인가:
  plpgsql 로는 알림을 기다릴 수 없다. pg_sleep() 은 NOTIFY 로 깨지 않으므로
  "알림이 올 때까지 블록"을 서버 안에서 표현할 방법이 없다. 그래서 워커를 클라이언트로
  내보내되, **두 방식이 완전히 같은 코드·같은 denorm_drain() 을 쓰도록** 했다.
  둘을 각각 plpgsql/파이썬으로 짜면 깨우는 방식이 아니라 언어와 왕복 비용을 비교하게 된다.

의존성: psycopg2  (pip install psycopg2-binary)

다섯 가지 깨우는 방식
  poll     : 큐가 비면 고정 간격으로 잠들었다 다시 본다
  notify   : 알림이 올 때까지 블록한다 (즉시 기동)
  debounce : 알림이 오면 **곧바로 처리하지 않고** 고정 창(window) 동안 더 모은 뒤 처리한다
             → 쓰기가 잦을 때 notify 가 트랜잭션마다 깨어나 바쁜 폴링으로 퇴화하는 것을 막는다.
               대가는 창 길이만큼의 지연이고, **한산할 때는 모을 것이 없어 순손해**다.
  adaptive : 고정 창 대신 **drain 사이의 최소 간격**을 보장한다. 기다릴 시간을 그때그때
             계산한다 — 직전 drain 이후 이미 그만큼 지났으면 0 을 기다린다.
             · 한산: 알림이 드물어 간격이 이미 벌어져 있다 → 대기 0 → notify 와 같은 지연
             · 바쁨: 연속으로 깨어나므로 간격이 걸린다 → 자동으로 모아 큰 배치가 된다
             즉 한 설정으로 두 구간을 다 감당하는 것이 목적이다. 설정값의 의미는
             "초당 drain 을 최대 1000/M 회로 제한한다"이다.
             **약점**: 시간만 보므로 큐에 일이 쌓여 있어도 간격을 채운다 — 페이싱이 곧 지연이 된다.
  qdepth   : adaptive 에 **큐 깊이** 신호를 더한다. drain 이 남은 깊이를 함께 돌려주므로
             (추가 왕복 없음) 그걸 보고 판단한다.
             · 남은 깊이 >= 임계치 → 기다릴 이유가 없다. 이미 모여 있으니 **즉시** 다음 배치
             · 남은 깊이 <  임계치 → adaptive 처럼 최소 간격을 지킨다
             시간 기반 페이싱이 "일이 쌓였는데도 기다리는" 경우를 없애는 것이 목적이다.

사용:
  ./t9_worker.py --mode poll     --sleep-ms 20        --batch 2000 --secs 30 --stats /tmp/w.txt
  ./t9_worker.py --mode notify                        --batch 2000 --secs 30 --stats /tmp/w.txt
  ./t9_worker.py --mode debounce --debounce-ms 20     --batch 2000 --secs 30 --stats /tmp/w.txt
  ./t9_worker.py --mode adaptive --min-interval-ms 20 --batch 2000 --secs 30 --stats /tmp/w.txt
  ./t9_worker.py --mode qdepth   --min-interval-ms 20 --depth-threshold 500 --batch 2000 --secs 30

--stats 파일에는 "처리배치수 빈폴링수 처리항목수" 를 한 줄로 남긴다.
빈 폴링 수 = 큐가 비어 있는데 깨어나 헛일한 횟수 = 깨우는 방식이 낭비하는 왕복.
"""
import argparse, select, signal, time, sys

try:
    import psycopg2, psycopg2.extensions
except ImportError:
    sys.stderr.write("psycopg2 가 필요합니다: pip install psycopg2-binary\n")
    sys.exit(2)

ap = argparse.ArgumentParser()
ap.add_argument('--mode', choices=['poll', 'notify', 'debounce', 'adaptive', 'qdepth'], default='poll')
ap.add_argument('--sleep-ms', type=float, default=20.0)
ap.add_argument('--debounce-ms', type=float, default=20.0)
ap.add_argument('--min-interval-ms', type=float, default=20.0)
ap.add_argument('--depth-threshold', type=int, default=500)
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
if a.mode in ('notify', 'debounce', 'adaptive', 'qdepth'):
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

last_drain = 0.0    # 마지막 drain 시각 (adaptive/qdepth 의 페이싱 기준)
depth = 0           # 직전 drain 이 알려준 남은 큐 깊이 (qdepth 의 신호)

while time.monotonic() < deadline:
    # adaptive: drain 사이에 최소 간격을 둔다. **기다릴 시간을 계산한다** —
    # 직전 drain 이후 이미 간격만큼 지났으면 한 톨도 기다리지 않는다.
    # 그래서 한산할 때는 고정 창과 달리 지연이 붙지 않고, 바쁠 때만 모으는 효과가 난다.
    # qdepth: 이미 쌓여 있으면 페이싱을 건너뛴다. 기다려서 더 모을 이유가 없기 때문이다.
    if a.mode in ('adaptive', 'qdepth') and last_drain \
       and not (a.mode == 'qdepth' and depth >= a.depth_threshold):
        wait = a.min_interval_ms / 1000.0 - (time.monotonic() - last_drain)
        remaining = deadline - time.monotonic()
        if wait > 0 and remaining > 0:
            time.sleep(min(wait, remaining))
            conn.poll()
            del conn.notifies[:]

    cur.execute("SELECT applied, depth FROM denorm_drain(%s)", (a.batch,))
    last_drain = time.monotonic()
    n, depth = cur.fetchone()
    if n:
        batches += 1
        applied += n
        continue
    depth = 0

    empty += 1
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        break

    if a.mode == 'poll':
        time.sleep(min(a.sleep_ms / 1000.0, remaining))
        continue

    # ── notify / debounce / adaptive: 알림을 기다린다 ──
    # 놓친 알림이 없도록 순서가 중요하다.
    #   1) 이미 도착해 버퍼에 있는 알림을 먼저 확인한다.
    #   2) 없으면 소켓에서 기다린다. drain 과 select 사이에 도착한 알림은
    #      소켓 버퍼에 남아 select 가 곧바로 readable 로 보고하므로 유실되지 않는다.
    # 타임아웃은 깨우는 수단이 아니라 안전장치일 뿐이다 — 알림은 저장되지 않으므로
    # (워커가 죽어 있는 동안 발행된 알림은 사라진다) 주기적으로 큐를 직접 확인해야 한다.
    conn.poll()
    got = bool(conn.notifies)
    if got:
        del conn.notifies[:]
    else:
        if select.select([conn], [], [], min(0.5, remaining))[0]:
            conn.poll()
            got = bool(conn.notifies)
            del conn.notifies[:]

    # debounce: 첫 알림을 받았어도 곧바로 처리하지 않고 창 동안 더 모은다.
    # notify 는 트랜잭션마다 깨어나므로 쓰기가 잦으면 한 건씩 처리하며 왕복만 늘어난다.
    # 창을 두면 그 사이 커밋된 변경들이 한 배치로 묶인다. 대가는 창 길이만큼의 지연.
    if a.mode == 'debounce' and got:
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(a.debounce_ms / 1000.0, remaining))
            conn.poll()
            del conn.notifies[:]

write_stats()
