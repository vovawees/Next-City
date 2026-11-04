NEXT-CITY / .ai — KNOWLEDGE BASE FOR AGENTS AND MAINTAINERS
format: dry dense plain text, english identifiers, no secrets (tokens/keys never stored here or in git).
update rule: refresh after every logical step and before the final push of a work session.

FILES
  architecture.txt  layers L0-L4, boot, packages, module contract, data flow, key decisions (D1..)
  stack.txt         languages, runtime, tools, versions, local and VPS toolchains, commands
  modules.txt       module map (part generated: luajit tools/modmap.lua) + per-module notes
  net.txt           net messages, schema types, budgets, component replication, rates
  testing.txt       emulator (tests/gmod), spec list, lint rules, how to run, pitfalls
  vps.txt           VPS host, folders, tmux sessions, ports, what runs there
  github.txt        repo, issues/milestones map, commit and push rules
  status.txt        milestone status, done/in progress per issue
  bugs.txt          known bugs, emulator vs real GMod gaps, things to measure in real GMod
  next.txt          ordered next steps

QUICK START (fresh machine)
  git clone https://github.com/vovawees/Next-City.git && cd Next-City
  luajit 2.1 + glualint on PATH (see stack.txt) ; luajit tests/run.lua ; glualint lint gamemodes tests
