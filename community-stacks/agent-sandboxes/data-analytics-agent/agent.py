"""Minimal LangChain agent: analyzes an Excel file with pandas inside an Agent Sandbox,
using a model on Amazon Bedrock. Which model is up to you: set BEDROCK_MODEL_ID to a
Bedrock model ID or inference profile ID that supports tool use and that your account
has access to in AWS_REGION.

Two separate credentials, both short-lived, neither in this file:
  - AWS (Bedrock): the standard AWS credential chain, e.g. an IAM Identity Center
    profile (aws sso login --profile sandbox-agent; export AWS_PROFILE=sandbox-agent)
    or the IAM role of the machine running the agent. Needs bedrock-agent-iam-policy.json.
  - Kubernetes (sandbox): KUBECONFIG for the "agent" ServiceAccount in the tenant
    cluster (claim sandboxes + port-forward to the router). The SDK reaches the router
    through `kubectl port-forward`, so kubectl must be on PATH.

pip install langchain langchain-aws k8s-agent-sandbox
export AWS_PROFILE=sandbox-agent KUBECONFIG=./agent.kubeconfig
export BEDROCK_MODEL_ID=<model-or-inference-profile-id>
python agent.py sales.xlsx "Which region had the highest revenue, and by how much?"
"""
import os
import sys
import time

from langchain.agents import create_agent
from langchain.tools import tool
from langchain_aws import ChatBedrockConverse
from k8s_agent_sandbox import SandboxClient
from k8s_agent_sandbox.models import SandboxLocalTunnelConnectionConfig

# Required, no default: the Bedrock model ID or inference profile ID to use.
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "")
AWS_REGION = os.environ.get("AWS_REGION", "eu-central-1")

# Names created by the agent-sandbox Stack.
WARMPOOL = "python-pool"
SANDBOX_NAMESPACE = "agent-sandboxes"

# Which agent this is. Set on the claim as the label vBox attributes sessions by, so
# parallel agents show up separately on its Audit page.
AGENT_NAME = os.environ.get("AGENT_NAME", "data-analytics-agent")
# Keep the sandbox for at least this long before terminating it, to simulate a longer
# interaction. 0 terminates it as soon as the agent has answered.
MIN_LIFETIME = float(os.environ.get("SANDBOX_MIN_LIFETIME_SECONDS", "0"))


def log(msg: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def main(xlsx_path: str, question: str) -> None:
    if not MODEL_ID:
        sys.exit("Set BEDROCK_MODEL_ID to the Bedrock model ID or inference profile ID to use.")
    llm = ChatBedrockConverse(model=MODEL_ID, region_name=AWS_REGION, max_tokens=4096, temperature=0)

    client = SandboxClient(connection_config=SandboxLocalTunnelConnectionConfig())
    log(f"claiming a sandbox from {WARMPOOL}")
    sandbox = client.create_sandbox(
        warmpool=WARMPOOL,
        namespace=SANDBOX_NAMESPACE,
        labels={"agents.x-k8s.io/created-by": AGENT_NAME},
    )
    ready_at = time.monotonic()
    claim = sandbox.claim_name  # terminate() clears it
    log(f"sandbox ready: claim {claim}")
    try:
        # Upload the spreadsheet; pandas is in the image, openpyxl (Excel reader) is not.
        with open(xlsx_path, "rb") as f:
            sandbox.files.write("data.xlsx", f.read())
        sandbox.commands.run("python3 -m pip install --user --quiet openpyxl", command_timeout=120)

        @tool
        def run_python(code: str) -> str:
            """Run Python code in the sandbox and return its output. The spreadsheet is ./data.xlsx."""
            sandbox.files.write("main.py", code)
            r = sandbox.commands.run("python3 main.py", command_timeout=120)
            return f"exit={r.exit_code}\nstdout:\n{r.stdout}\nstderr:\n{r.stderr}"[-8000:]

        agent = create_agent(
            llm,
            tools=[run_python],
            system_prompt=(
                "You are a data analyst. Answer questions about ./data.xlsx by writing pandas "
                "code and running it with run_python. Inspect sheets and columns first. Whenver executing the run_python function wait addiitonal 20s before completing."
                "Print results; fix errors and retry. Base your answer only on printed output."
            ),
        )
        result = agent.invoke({"messages": [{"role": "user", "content": question}]})
        print(result["messages"][-1].content)
    finally:
        hold = MIN_LIFETIME - (time.monotonic() - ready_at)
        if hold > 0:
            log(f"holding sandbox {claim} {hold:.0f}s more to reach the {MIN_LIFETIME:.0f}s minimum lifetime")
            time.sleep(hold)
        sandbox.terminate()
        log(f"sandbox terminated: claim {claim}, alive {time.monotonic() - ready_at:.0f}s")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])