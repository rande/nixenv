---
id: TPL-10
title: "Services exec in the foreground and wait for dependencies"
area: templates
applies-to:
  - "templates/**"
  - "tests/lib-template.sh"
  - "tests/unit/1*-template-*.sh"
---

# TPL-10: Services exec in the foreground and wait for dependencies

## Rule

- Each `run` script MUST `exec` a FOREGROUND process and wait for what it needs
  with a short `sleep; exit 0` (runsv retries).
- A first-run hook that needs a database starts a temporary one and shuts it
  down afterwards (setup runs BEFORE services).
- Probe postgres AS the cluster's role and database (`pg_isready -U <role>
  -d <db>`).

## Why

A bare probe uses the login user `app` and postgres logs
`FATAL: role/database "app" does not exist` on every attempt.

## How

Exiting is the throttle; runsv restarts the script.
