# data-analytics-agent

Example agent for Agent Sandboxes: a LangChain agent on Amazon Bedrock that analyzes
a spreadsheet with pandas inside a sandbox claimed from the `python-pool` warm pool.

- `agent.py` runs one agent against one question.
- `run_agents.py` is the smoke test: several agents at once, each in its own sandbox.
- `data.xlsx` is the sample workbook both use.

Setup and usage are in the [Agent Sandboxes README](../README.md#smoke-test).
