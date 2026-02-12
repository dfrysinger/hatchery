# Agent Isolation - Architecture

## Feature Issue
GitHub Issue #222 | Milestone: R6: Agent Isolation

## Overview
Agent Isolation adds three isolation levels to hatchery habitats, allowing operators
to run agent groups in separate processes (session mode) or Docker containers
(container mode), while preserving backward compatibility with v2 schemas.

## Isolation Levels

| Level | Process Model | Filesystem | Network | Status |
|-------|--------------|------------|---------|--------|
| none | Shared OpenClaw process | Shared | Shared | Default |
| session | Separate systemd service per group | Shared | Shared | Implemented |
| container | Docker container per group | Explicit volumes | Configurable | Implemented |
| droplet | Separate DO droplet | Isolated | Isolated | Reserved (future) |

## Session Mode Architecture

When `isolation=session`, `generate-session-services.sh` creates:
- One systemd servi# Agent Isolation - Architecture

## Feature Issue
GitHub Issue #222 | Milestone: R6: Agent Isolation

##87
## Feature Issue
GitHub Issue at GitHub Issue #2aw
## Overview
Agent Isolation adds three isolationin Agent Isolmato run agent groups in separate processes (session mode) or Docker containers
(contRO(container mode), while preserving backward compatibility with v2 schemas.

  
## Isolation Levels

| Level | Process Model | Filesystem | Network | Stunc
| Level | Procet 187|-------|--------------|------------|---------|--------|| | none | Shared OpenClaw process | Shared | Shared | Decl| session | Separate systemd service per group | Sharedpenclaw.| container | Docker container per group | Explicit volumes | Configurable | Imrc| droplet | Separate DO droplet | Isolated | Isolated | Reserved (future) |

## Session Mco
## Session Mode Architecture

When `isolation=session`, `generate-sessionher
When `isolati` (configurable - One systemd servi# Agent Isolation - Architecture

## Feature gr
## Feature Issue
GitHub Issue #222 | Milestone: Rt` (default), `inter
##87
## Feature Issue
GitHub Issue at GitHub Issd `## s`GitHub Issue aton## Overview
Agent Isolation adds# Agent Isolat(contRO(container mode), while preserving backward compatibility with v2 schemas.

  
## Isolation Levels

| Level | Process Mo- 
  
## Isolation Levels

| Level | Process Model | Filesystem | Network | Stunc
es #nl
| Level | Processde | Level | Procet 187|-------|--------------|---------Gr
## Session Mco
## Session Mode Architecture

When `isolation=session`, `generate-sessionher
When `isolati` (configurable - One systemd servi# Agent Isolation - Architecture

## Feature gr
## Feature Issue
GitHub Issue #222 | Milestone: Rt` (default), `inter
##87
## Feature Issue
GitHub Issue at GitHub Issd `## s`GitHub Issue aton## Overview
Agent Iso(16## Session Moes
When `isolation=session`, y` When `isolati` (configurable - One systemd se_s
## Feature gr
## Feature Issue
GitHub Issue #222 | Milestone: Rt` (default), `Ses## Feature IioGitHub Issue #2`t##87
## Feature Issue
GitHub Issue at GitHub Issd `erationGitHub Issue at# Agent Isolation adds# Agent Isollation-session.json`
- `example
  
## Isolation Levels

| Level | Process Mo- 
  
## Isolation Levels

| Level | Process Model | Filesystem | Netpip#li
| Level | Processnfi  
## Isolation Levelal#sh
, `phase2-backgroundes #nl
| Level | PrASK-206.

## Patterns Reused
- Env v| Levur## Session Mco
## Session Mode Architecture

When `isolation=session`, `geaw## Session Mo)

When `isolation=session`, tabWheny
