import re

with open('src/prompts/append-system-prompt.ts', 'r') as f:
    content = f.read()

# Define the exact pattern to match and replacement
old_pattern = """# Workflow Notes

- Prefer \`task list\` first when task IDs or dependency IDs are needed.
- To create multiple linked tasks, create tasks first, then call \`task link\` for each dependency edge.
\`;
}"""

new_pattern = """# Workflow Notes

- Prefer \`task list\` first when task IDs or dependency IDs are needed.
- To create multiple linked tasks, create tasks first, then call \`task link\` for each dependency edge.

${
\tprocess.env.KANBAN_ENABLE_AGENT_TEAMS === "true"
\t\t? \`# Agent Teams

Agent Teams are enabled for this workspace. Every task you start will have agent team capabilities — the coding agent running in the task's worktree can spawn teammate sub-agents to work on subtasks in parallel. You don't need to do anything special; just start tasks normally with \`task start\`.
\`
\t\t: ""
}\`;
}"""

# Replace the content
if old_pattern in content:
    content = content.replace(old_pattern, new_pattern)
    with open('src/prompts/append-system-prompt.ts', 'w') as f:
        f.write(content)
    print("Replacement successful")
else:
    print("Old pattern not found - checking for similar patterns")
    
    # Let's find the context around line 303
    lines = content.split('\n')
    for i, line in enumerate(lines[295:310], start=296):
        print(f"Line {i}: {repr(line)}")
