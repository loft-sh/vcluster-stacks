"""Fires several data analytics agents at once to exercise sandbox creation and teardown.

Each agent is its own agent.py process, so each claims its own Python sandbox from the
warm pool, opens its own port-forward to the Sandbox Router, and terminates its claim
when done. Every sandbox is held for at least --min-lifetime seconds (default 30), so
the claims overlap and the warm pool has to refill while they are still in use.

Same credentials as agent.py: AWS for Bedrock, KUBECONFIG for the tenant cluster.

export AWS_PROFILE=sandbox-agent KUBECONFIG=./agent.kubeconfig
uv run python run_agents.py                    # 4 agents, 30 s minimum per sandbox
uv run python run_agents.py --agents 6 --min-lifetime 60 --stagger 2
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

# One question per agent, so the four runs do different work. Cycled past four.
QUESTIONS = [
    "Which region had the highest revenue, and by how much did it beat the second?",
    "Which product category has the best gross margin percentage?",
    "Which sales rep sold the most units, and through which channel?",
    "How did monthly revenue develop over the year? Name the best and the worst month.",
]


def run_agent(name: str, question: str, args: argparse.Namespace, results: dict, lock: threading.Lock) -> None:
    env = {**os.environ, "AGENT_NAME": name, "SANDBOX_MIN_LIFETIME_SECONDS": str(args.min_lifetime)}
    started = time.monotonic()
    proc = subprocess.Popen(
        [sys.executable, str(HERE / "agent.py"), str(args.xlsx), question],
        cwd=HERE, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1,
    )
    claim, alive = None, None
    for line in proc.stdout:
        line = line.rstrip()
        with lock:
            print(f"[{name}] {line}", flush=True)
        if m := re.search(r"sandbox ready: claim (\S+)", line):
            claim = m.group(1)
        if m := re.search(r"sandbox terminated: claim \S+, alive (\d+)s", line):
            alive = int(m.group(1))
    results[name] = {
        "exit": proc.wait(),
        "claim": claim,
        "alive": alive,
        "duration": time.monotonic() - started,
    }


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--agents", type=int, default=4, help="number of agents to run at once (default 4)")
    p.add_argument("--min-lifetime", type=float, default=30, help="minimum seconds each sandbox stays alive (default 30)")
    p.add_argument("--stagger", type=float, default=0, help="seconds between agent starts (default 0: all at once)")
    p.add_argument("--xlsx", type=Path, default=HERE / "data.xlsx", help="spreadsheet each agent analyzes")
    args = p.parse_args()

    if not shutil.which("kubectl"):
        sys.exit("kubectl is not on PATH; the sandbox SDK port-forwards to the router with it.")
    if not args.xlsx.is_file():
        sys.exit(f"{args.xlsx} not found.")
    if not os.environ.get("KUBECONFIG"):
        print("WARN: KUBECONFIG is not set; using the current kubectl context.", file=sys.stderr)

    results: dict = {}
    lock = threading.Lock()
    threads = []
    print(f"Starting {args.agents} agents, each holding its sandbox for at least {args.min_lifetime:.0f}s\n")
    for i in range(args.agents):
        name = f"agent-{i + 1}"
        t = threading.Thread(target=run_agent, args=(name, QUESTIONS[i % len(QUESTIONS)], args, results, lock))
        t.start()
        threads.append(t)
        if args.stagger and i < args.agents - 1:
            time.sleep(args.stagger)
    for t in threads:
        t.join()

    print(f"\n{'agent':10} {'exit':>4} {'sandbox alive':>14} {'agent ran':>10}  claim")
    failed = False
    for i in range(args.agents):
        name = f"agent-{i + 1}"
        r = results[name]
        alive = f"{r['alive']}s" if r["alive"] is not None else "-"
        short = r["alive"] is not None and r["alive"] < args.min_lifetime
        failed |= r["exit"] != 0 or r["alive"] is None or short
        note = "  (shorter than the minimum)" if short else ""
        print(f"{name:10} {r['exit']:>4} {alive:>14} {r['duration']:>9.0f}s  {r['claim'] or '-'}{note}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
