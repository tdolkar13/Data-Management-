"""Replays concurrency_demo.sql with two real connections (threads). Usage: python concurrency_runner.py scrollsense.db"""
import sqlite3, threading, time, shutil, sys
SRC=sys.argv[1] if len(sys.argv)>1 else 'scrollsense.db'; DB='concurrency_demo_copy.db'
shutil.copy(SRC,DB)
def conn():
    c=sqlite3.connect(DB,isolation_level=None,timeout=5.0,check_same_thread=False); c.execute("PRAGMA journal_mode=WAL")
    c.execute("PRAGMA foreign_keys=ON"); return c
s=conn()
s.execute("CREATE TABLE IF NOT EXISTS UserCredit(user_id INTEGER PRIMARY KEY REFERENCES AppUser(user_id), balance INTEGER NOT NULL CHECK(balance>=0)) STRICT")
LOG=[]; L=threading.Lock(); T0=0
def log(w,m):
    with L: LOG.append((len(LOG),f"  t={1000*(time.perf_counter()-T0):7.1f} ms  {w}: {m}"))
def reset():
    global T0,LOG; LOG=[]; s.execute("DELETE FROM UserCredit WHERE user_id=1"); s.execute("INSERT INTO UserCredit VALUES(1,100)"); T0=time.perf_counter()
def bal(c): return c.execute("SELECT balance FROM UserCredit WHERE user_id=1").fetchone()[0]
def go(*ts):
    th=[threading.Thread(target=f,args=a) for f,a in ts]; [t.start() for t in th]; [t.join() for t in th]
out=[]
def finish(title):
    final=bal(s); out.append(f"\n### {title}"); out.extend(m for _,m in sorted(LOG))
    out.append(f"  FINAL balance = {final}  (correct = 130)  -> {'OK' if final==130 else 'LOST UPDATE'}")
# Run 1: unprotected
def unsafe(name,delta,bar):
    c=conn(); b=bal(c); log(name,f"READ balance = {b}"); bar.wait()
    c.execute("UPDATE UserCredit SET balance=? WHERE user_id=1",(b+delta,)); log(name,f"WRITE balance = {b+delta}"); c.close()
reset(); bar=threading.Barrier(2); go((unsafe,("T_A",-20,bar)),(unsafe,("T_B",+50,bar))); finish("Run 1  UNPROTECTED (autocommit read, then write)")
# Run 2: BEGIN IMMEDIATE
def immediate(name,delta,delay,hold):
    time.sleep(delay); c=conn(); log(name,"BEGIN IMMEDIATE requested"); t=time.perf_counter()
    c.execute("BEGIN IMMEDIATE"); log(name,f"BEGIN IMMEDIATE granted (waited {1000*(time.perf_counter()-t):.0f} ms)")
    b=bal(c); log(name,f"READ balance = {b}"); time.sleep(hold)
    c.execute("UPDATE UserCredit SET balance=? WHERE user_id=1",(b+delta,)); log(name,f"WRITE balance = {b+delta}")
    c.execute("COMMIT"); log(name,"COMMIT"); c.close()
reset(); go((immediate,("T_A",-20,0.0,0.3)),(immediate,("T_B",+50,0.05,0.3))); finish("Run 2  FIX: BEGIN IMMEDIATE around read-modify-write")
# Run 3: deferred BEGIN + retry
def deferred(name,delta,bar,tries):
    c=conn(); n=0
    while True:
        n+=1
        try:
            c.execute("BEGIN"); b=bal(c); log(name,f"READ balance = {b} (try {n})")
            if n==1: bar.wait()
            c.execute("UPDATE UserCredit SET balance=? WHERE user_id=1",(b+delta,)); log(name,f"WRITE balance = {b+delta}")
            c.execute("COMMIT"); log(name,"COMMIT"); break
        except sqlite3.OperationalError as e:
            log(name,f"!! {e} -> ROLLBACK, retry"); c.execute("ROLLBACK"); time.sleep(0.01)
    tries[name]=n; c.close()
reset(); bar=threading.Barrier(2); tr={}; go((deferred,("T_A",-20,bar,tr)),(deferred,("T_B",+50,bar,tr))); finish("Run 3  ALTERNATIVE: plain BEGIN + retry on 'database is locked'"); out.append(f"  attempts: {tr}")
# Run 4: atomic UPDATE
def atomic(name,delta):
    c=conn(); c.execute("UPDATE UserCredit SET balance=balance+? WHERE user_id=1",(delta,)); log(name,f"UPDATE balance = balance {delta:+d}"); c.close()
reset(); go((atomic,("T_A",-20)),(atomic,("T_B",+50))); finish("Run 4  ALTERNATIVE: atomic UPDATE balance = balance + delta (no read in the app)")
print("\n".join(out)); open('concurrency_trace.txt','w').write("\n".join(out))
